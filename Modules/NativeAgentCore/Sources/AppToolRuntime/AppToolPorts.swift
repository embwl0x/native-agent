import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ChatTurnRuntime
import ChatTurnContracts
import ProviderRouting
import Browser
import Senses
import Dispatcher
import MacControl
import AgentWorkspace
import AgentConversations
import AuthoredCapabilities
import ToolExecution
// Blueprint: | `AppToolPorts.swift` | `AppActionExecution`, `BrowserToolPlatformPort`, `QuietToolPresentationPort`: operation ports |

/// The app operation's call stack and injected gates. This is passed to each
/// nested call, never stored on a turn or inherited by a task.
public struct AppActionExecution: Sendable {
    /// The held work owns the invocation, which alone stores its ceilings.
    public var invocation: ChatToolInvocation {
        get { turnWork.toolInvocation }
        set { turnWork.toolInvocation = newValue }
    }
    public var deadlines: OperationDeadlines {
        get { turnWork.deadlines }
        set { turnWork.deadlines = newValue }
    }
    public var turnWork: ChatTurnWork
    public var admitModel: (@Sendable (Turn?) async throws -> Turn)?
    public typealias Perform = @Sendable (String, [String: JSONValue], Turn, AppActionExecution) async throws -> JSONValue
    public var perform: Perform?
    public var validate: (@Sendable (String, [String: JSONValue], Turn) async -> JSONValue?)?
    public var waitForInteraction: (@Sendable (InlineInteraction, String, [String: JSONValue], Turn) async -> JSONValue)?
    public var host: (any OwnedProgramToolHost)?
    public var openScreenWatch: (@Sendable (MacScreenWatch.Request, Bool, Turn) async throws -> MacScreenWatch)?
    public var undoReceipt: JSONValue?
    public var argumentPreflightOnly = false
    var notesSnapshot: DoorNotesSnapshot?
    public var handsBack = false
    public var wake: JSONValue?
    public var valueCall: (id: String, version: String)?
    public var arrived: (@Sendable () -> Parts.Arrival?)?
    public var admissionOnly = false
    public var authoredCall: (tool: String, perform: @Sendable () async throws -> JSONValue)?
    public var workspaceMacCall = false
    public var lookSource = "direct"
    public var readingRaw = false
    public var verifyingActCorner: SenseCorner?
    public var senseAct = false
    public var retainBrowserRead: (@Sendable (BrowserVisibleCapture) -> Void)?
    public var localImageSink: LocalToolImage.Sink?
    public var generatedImagePaths: Set<String> = []
    public init(invocation: ChatToolInvocation, deadlines: OperationDeadlines, turnWork: ChatTurnWork) {
        self.turnWork = turnWork
        self.invocation = invocation
        self.deadlines = deadlines
        self = receiving(self.invocation)
    }

    /// Forward refinements made by an app action to the operation-aware dispatcher.
    public var toolInvocation: ChatToolInvocation {
        var invocation = invocation
        invocation.handsBack = handsBack
        invocation.wake = wake
        invocation.valueCall = valueCall
        invocation.programHost = host
        invocation.insideWorkspace = workspaceMacCall
        invocation.frameSource = lookSource
        invocation.readingRaw = readingRaw
        invocation.imageSink = localImageSink
        if let authoredCall { invocation.authoredCall = authoredCall }
        return invocation
    }

    func receiving(_ invocation: ChatToolInvocation) -> Self {
        var execution = self
        execution.invocation = invocation
        execution.handsBack = invocation.handsBack
        execution.wake = invocation.wake
        execution.valueCall = invocation.valueCall
        if let host = invocation.programHost { execution.host = host }
        execution.workspaceMacCall = invocation.insideWorkspace
        execution.lookSource = invocation.frameSource
        execution.readingRaw = invocation.readingRaw
        execution.localImageSink = invocation.imageSink
        if execution.perform == nil, let door = invocation.appDoor {
            execution.perform = { tool, input, turn, execution in
                try await door.perform(tool, input, turn, execution.toolInvocation)
            }
            execution.validate = { tool, input, turn in
                await door.validate(tool, input, turn, invocation)
            }
        }
        return execution
    }

    func programExecution(turn: Turn?, surface: String, preview: Bool = false) -> OwnedProgramExecution {
        OwnedProgramExecution(turn: turn, surface: surface, deadlines: deadlines, preview: preview, wake: wake,
            options: .init(handsBack: handsBack), readContent: invocation.readContent,
            valueIdentity: valueCall, deadline: invocation.waitDeadline, onActivity: { deadlines.progressed() })
    }

    func partInvocation(turn: Turn, surface: String, preview: Bool = false) -> Parts.Invocation {
        .init(host: host, execution: programExecution(turn: turn, surface: surface, preview: preview), arrived: arrived,
            progressed: { deadlines.progressed() },
            openScreenWatch: openScreenWatch.map { open in { @Sendable request, hands in try await open(request, hands, turn) } })
    }

    func senseOperation(turn: Turn?, perform: SenseActionContext.Perform? = nil) -> SenseReadOperation {
        var operation = invocation.senseRead ?? .init(turn: turn, appCapture: invocation.readCapture,
            senseReads: invocation.senseReads, readContent: invocation.readContent,
            passive: invocation.passiveObservation, deadline: invocation.waitDeadline)
        operation.turn = turn
        operation.options = .init(raw: readingRaw, verifyingActCorner: verifyingActCorner)
        operation.perform = perform
        return operation
    }

    public func macOperation(dataRoot: URL) -> MacOperationContext {
        var context = invocation.macContext(dataRoot: dataRoot)
        context.handsBack = handsBack
        return context
    }

    func serving(_ program: OwnedProgramExecution) -> Self {
        var execution = self
        execution.handsBack = program.options.handsBack
        execution.wake = program.wake
        execution.valueCall = program.valueIdentity
        execution.invocation.readContent = program.readContent
        execution.invocation.waitDeadline = program.deadline
        execution.deadlines = program.deadlines
        return execution
    }
}

public struct BrowserToolPlatformPort: Sendable {
    public let setUpChrome: @Sendable () async throws -> (folder: URL?, message: String)
    public let readStatus: @Sendable () async throws -> JSONValue
    public let runNativeAction: @Sendable (String, Bool, [String: JSONValue], Turn, AppActionExecution) async throws -> JSONValue
    public init(
        setUpChrome: @escaping @Sendable () async throws -> (folder: URL?, message: String),
        readStatus: @escaping @Sendable () async throws -> JSONValue,
        runNativeAction: @escaping @Sendable (String, Bool, [String: JSONValue], Turn, AppActionExecution) async throws -> JSONValue
    ) { self.setUpChrome = setUpChrome; self.readStatus = readStatus; self.runNativeAction = runNativeAction }
}

/// Mounted window ports carry values/actions; policy remains in the Core caller.
@MainActor public protocol QuietToolHost: QuietSettingsHost {
    var activeChatSessionId: String { get }
    func pageRead(_ page: QuietToolPage, turn: Turn) async -> [JSONValue]
    /// Empty sessionId targets the visible conversation.
    func composerState(sessionId: String, turn: Turn) async -> [String: JSONValue]
    /// Attachments are already resolved and fenced; turnSessionId retains the asking conversation's __session_id.
    func runComposer(
        verb: String, value: String, choice: String, sessionId: String, attachments: [URL], reachesUser: Bool,
        turnSessionId: String, turn: Turn
    ) async -> QuietComposerOutcome
    /// Core admits chat_session posture; reachesUser permits screen, sound and user-conversation effects.
    func runChatSession(verb: String, input: [String: JSONValue], reachesUser: Bool, turn: Turn) async -> JSONValue
    /// Read-only app fences are shared by preview and execution, including screen, sound, drafts and conversation ownership.
    func composerFence(verb: String, value: String, sessionId: String, reachesUser: Bool, turnSessionId: String, turn: Turn)
        -> QuietComposerOutcome?
    func chatSessionFence(verb: String, input: [String: JSONValue], reachesUser: Bool, turn: Turn) -> JSONValue?
    func saveProviderKey(_ key: String, provider: String) async -> NativeOAuthFlow.InlineSetupOutcome
    func runUpkeep(verb: String, input: [String: JSONValue], turn: Turn) async -> (ok: Bool, detail: String, fields: [String: JSONValue])
    /// Upkeep previews use effect-free input and target checks.
    func upkeepFence(verb: String, input: [String: JSONValue]) async -> JSONValue?
    /// Inbox reads and actions share the page's owner.
    func inbox(verb: String, input: [String: JSONValue], turn: Turn) async -> JSONValue
    /// Inbox preview shares execution's pre-write checks without mutation.
    func inboxFence(verb: String, input: [String: JSONValue], turn: Turn) async -> JSONValue?
    /// Mind verbs use the page controls' execution owner.
    func runMind(verb: String, input: [String: JSONValue], turn: Turn) async -> (ok: Bool, detail: String, fields: [String: JSONValue])
    /// Part execution retains peers and the originating operation's ceilings and callbacks.
    func managePart(verb: String, input: [String: JSONValue], steer: [String], turn: Turn,
                    invocation: Parts.Invocation) async -> (ok: Bool, detail: String, fields: [String: JSONValue])
    /// Core refuses access-raising connection verbs before platform execution.
    func connections(verb: String, input: [String: JSONValue], turn: Turn) async -> JSONValue
    /// Provider actions use the same owner as page buttons.
    func provider(verb: String, input: [String: JSONValue], turn: Turn) async -> JSONValue
}

public struct QuietComposerOutcome: Sendable {
    public var changed: Bool
    public var element: String
    public var detail: String
    public var status: String
    public var refusal: (reason: String, detail: String, effects: ToolFailureError.Effects)?
    public var remedy: JSONValue? = nil
    public init(changed: Bool, element: String, detail: String, refusal: (reason: String, detail: String, effects: ToolFailureError.Effects)?,
        status: String = "ok") {
        self.changed = changed; self.element = element; self.detail = detail; self.refusal = refusal; self.status = status
    }
    public static func done(_ element: String, _ detail: String, changed: Bool = true, status: String = "ok") -> Self {
        Self(changed: changed, element: element, detail: detail, refusal: nil, status: status)
    }
    public static func refuse(_ element: String, _ reason: String, _ detail: String, effects: ToolFailureError.Effects = .none) -> Self {
        Self(changed: false, element: element, detail: detail, refusal: (reason, detail, effects))
    }
}

public typealias QuietToolPage = NativeAgentShared.QuietToolPage

@MainActor public protocol QuietToolPresentationPort: Sendable {
    var pages: [QuietToolPage] { get throws }
    var currentPage: QuietToolPage? { get }
    var visiblePageInput: [String: JSONValue]? { get }
    func page(named: String) -> QuietToolPage?
    func contextReceiptRead(input: [String: JSONValue]) async -> JSONValue
    func agentViewRead(input: [String: JSONValue]) async -> JSONValue
    func pageScreenshot(input: [String: JSONValue], imageSink: LocalToolImage.Sink?) async -> JSONValue
}

/// Desktop effects require the app's platform adapters.
public struct ChatToolPlatformPort: Sendable {
    public let grok: @Sendable ([String: JSONValue], URL, any ToolDispatchClient, String, Turn, MacOperationContext) async -> JSONValue
    public let desktopChat: @Sendable ([String: JSONValue], URL, Turn, MacOperationContext, AgentConversationContext) async -> JSONValue
    public let desktop: @Sendable ([String: JSONValue], any ToolDispatchClient, String, Turn, ChatTurnWork, MacOperationContext) async -> JSONValue
    public init(
        grok: @escaping @Sendable ([String: JSONValue], URL, any ToolDispatchClient, String, Turn, MacOperationContext) async -> JSONValue,
        desktopChat: @escaping @Sendable ([String: JSONValue], URL, Turn, MacOperationContext, AgentConversationContext) async -> JSONValue,
        desktop: @escaping @Sendable ([String: JSONValue], any ToolDispatchClient, String, Turn, ChatTurnWork, MacOperationContext) async -> JSONValue
    ) { self.grok = grok; self.desktopChat = desktopChat; self.desktop = desktop }
}
