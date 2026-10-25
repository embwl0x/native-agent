import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ChatTurnRuntime
import ChatTurnContracts
import ProviderRouting
// Blueprint: | `AppToolPorts.swift` | `BrowserToolPlatformPort` struct; `QuietToolPresentationPort` supplies mounted visible-page input separately from the Advanced sidebar page |

public struct BrowserToolPlatformPort: Sendable {
    public let setUpChrome: @Sendable () async throws -> (folder: URL?, message: String)
    public let readStatus: @Sendable () async throws -> JSONValue
    public let runNativeAction: @Sendable (String, Bool, [String: JSONValue]) async throws -> JSONValue
    public init(
        setUpChrome: @escaping @Sendable () async throws -> (folder: URL?, message: String),
        readStatus: @escaping @Sendable () async throws -> JSONValue,
        runNativeAction: @escaping @Sendable (String, Bool, [String: JSONValue]) async throws -> JSONValue
    ) { self.setUpChrome = setUpChrome; self.readStatus = readStatus; self.runNativeAction = runNativeAction }
}

/// Values and actions of the mounted window. Policy stays in the Core caller.
@MainActor public protocol QuietToolHost: QuietSettingsHost {
    var activeChatSessionId: String { get }
    func pageRead(_ page: QuietToolPage) async -> [JSONValue]
    /// Empty `sessionId` means the conversation on screen.
    func composerState(sessionId: String) async -> [String: JSONValue]
    /// `attachments` are files Core already resolved and fenced; `reachesUser`
    /// as for `runChatSession`; `turnSessionId` is the asking turn's own
    /// conversation (`__session_id`).
    func runComposer(
        verb: String, value: String, choice: String, sessionId: String, attachments: [URL], reachesUser: Bool,
        turnSessionId: String
    ) async -> QuietComposerOutcome
    /// One `chat_session` verb, already admitted by Core's posture gate.
    /// `reachesUser`: the asking turn may move User's screen, speak, and touch
    /// a conversation he is in (`AppToolExecutor.reachesUser`).
    func runChatSession(verb: String, input: [String: JSONValue], reachesUser: Bool) async -> JSONValue
    /// The checks `runComposer` and `runChatSession` make first (User's
    /// screen, his ears, his draft, a conversation he is in, her own),
    /// asked alone for the door's preview: reads only, nil when none refuses.
    func composerFence(verb: String, value: String, sessionId: String, reachesUser: Bool, turnSessionId: String)
        -> QuietComposerOutcome?
    func chatSessionFence(verb: String, input: [String: JSONValue], reachesUser: Bool) -> JSONValue?
    func saveProviderKey(_ key: String, provider: String) async -> NativeOAuthFlow.InlineSetupOutcome
    /// One upkeep button, through the call the button makes.
    func runUpkeep(verb: String, input: [String: JSONValue]) async -> (ok: Bool, detail: String, fields: [String: JSONValue])
    /// The upkeep executor's effect-free input and target checks.
    func upkeepFence(verb: String, input: [String: JSONValue]) async -> JSONValue?
    /// The `inbox` tool's verbs over the Inbox page's own reads and actions.
    func inbox(verb: String, input: [String: JSONValue]) async -> JSONValue
    /// The checks `inbox` makes before it writes, asked alone for the door's
    /// preview: reads only, nil when none refuses.
    func inboxFence(verb: String, input: [String: JSONValue]) async -> JSONValue?
    /// One `mind_run` verb, through the call its Dreams, Self-Improvement or
    /// Observatory control makes.
    func runMind(verb: String, input: [String: JSONValue]) async -> (ok: Bool, detail: String, fields: [String: JSONValue])
    /// One `ability_manage` verb (`Parts`), as the Tools page's own calls make it.
    /// `steer` names the peers steering this turn (`PeerDataTaint.carried`).
    func managePart(verb: String, input: [String: JSONValue], steer: [String]) async -> (ok: Bool, detail: String, fields: [String: JSONValue])
    /// The `connections` tool's verbs, through the Connectors and Telegram
    /// pages' own buttons. Core has already refused the raising ones.
    func connections(verb: String, input: [String: JSONValue]) async -> JSONValue
    /// One `provider` verb, through the call the Providers page's button makes.
    func provider(verb: String, input: [String: JSONValue]) async -> JSONValue
}

public struct QuietComposerOutcome: Sendable {
    public var changed: Bool
    public var element: String
    public var detail: String
    public var status: String
    public var refusal: (reason: String, detail: String, effects: ToolFailureError.Effects)?
    public var remedy: JSONValue? = nil
    public init(changed: Bool, element: String, detail: String, refusal: (reason: String, detail: String, effects: ToolFailureError.Effects)?, status: String = "ok") {
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
    var pages: [QuietToolPage] { get }
    var currentPage: QuietToolPage? { get }
    var visiblePageInput: [String: JSONValue]? { get }
    func page(named: String) -> QuietToolPage?
    func contextReceiptRead(input: [String: JSONValue]) async -> JSONValue
    func agentViewRead(input: [String: JSONValue]) async -> JSONValue
    func pageScreenshot(input: [String: JSONValue]) async -> JSONValue
}

/// Adapter to the existing interaction transaction owner (C2). No second inbox
/// or continuation state is kept by the tool runtime.
@MainActor public protocol ToolInteractionResolving: Sendable {
    func waitForAnswer(_ interaction: InlineInteraction, tool: String, input: [String: JSONValue], sessionID: String, dataRoot: URL) async -> JSONValue
    func interaction(id: String, sessionID: String, dataRoot: URL) async -> InlineInteraction?
    /// The conversation that raised a card, by its inbox note (`interaction:<id>`).
    func sessionID(ofCard id: String, dataRoot: URL) async -> String?
    func originEnvelope(of id: String, sessionID: String, dataRoot: URL) async -> TurnEnvelope?
    func descriptor(for interaction: InlineInteraction, dataRoot: URL) -> InlineInteractionDescriptor
    func begin(id: String, sessionID: String, expectedRevision: Int?, dataRoot: URL) async throws -> InlineInteraction
    func decline(id: String, sessionID: String, expectedRevision: Int?, dataRoot: URL) async throws -> InlineInteraction
    func returnToPending(_ interaction: InlineInteraction, sessionID: String, dataRoot: URL) async throws -> InlineInteraction
    func complete(id: String, sessionID: String, selection: String?, scope: InlineInteraction.Scope?, expectedRevision: Int?, attribution: String?, setupError: String?, note: String?, dataRoot: URL) async throws -> InlineInteraction
    func takeContinuationHandBack(id: String) -> String?
    func cardFields(_ interaction: InlineInteraction, descriptor: InlineInteractionDescriptor) -> [String: JSONValue]
    func receiptEnvelope(_ interaction: InlineInteraction) -> JSONValue
    func liveOutcomeSummary(_ interaction: InlineInteraction, dataRoot: URL) async -> String?
}

/// Desktop/Grok effects are still supplied by the app's platform adapters.
public struct ChatToolPlatformPort: Sendable {
    public let grok: @Sendable ([String: JSONValue], URL, any ToolDispatchClient, String) async -> JSONValue
    public let desktopChat: @Sendable ([String: JSONValue], URL) async -> JSONValue
    public let desktop: @Sendable ([String: JSONValue], any ToolDispatchClient, String) async -> JSONValue
    public init(
        grok: @escaping @Sendable ([String: JSONValue], URL, any ToolDispatchClient, String) async -> JSONValue,
        desktopChat: @escaping @Sendable ([String: JSONValue], URL) async -> JSONValue,
        desktop: @escaping @Sendable ([String: JSONValue], any ToolDispatchClient, String) async -> JSONValue
    ) { self.grok = grok; self.desktopChat = desktopChat; self.desktop = desktop }
}
