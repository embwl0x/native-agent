import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ChatOrchestration

public struct BrowserToolPlatformPort: Sendable {
    public let setUpChrome: @Sendable () async -> (folder: URL?, extensionsPageOpened: Bool, message: String)
    public let readStatus: @Sendable () async throws -> JSONValue
    public let runNativeAction: @Sendable (String, Bool, [String: JSONValue]) async throws -> JSONValue
    public init(
        setUpChrome: @escaping @Sendable () async -> (folder: URL?, extensionsPageOpened: Bool, message: String),
        readStatus: @escaping @Sendable () async throws -> JSONValue,
        runNativeAction: @escaping @Sendable (String, Bool, [String: JSONValue]) async throws -> JSONValue
    ) { self.setUpChrome = setUpChrome; self.readStatus = readStatus; self.runNativeAction = runNativeAction }
}

/// Values and actions of the mounted window. Policy stays in the Core caller.
@MainActor public protocol QuietToolHost: QuietSettingsHost {
    var activeChatSessionId: String { get }
    func pageRead(_ page: QuietToolPage) async -> (content: [JSONValue], rows: [JSONValue], truncated: Bool)
    func composerState() async -> [String: JSONValue]
    func runComposer(verb: String, value: String, choice: String) async -> QuietComposerOutcome
    func saveProviderKey(_ key: String, provider: String) async -> QuietProviderKeyOutcome
}

public struct QuietComposerOutcome: Sendable {
    public var changed: Bool
    public var element: String
    public var detail: String
    public var refusal: (reason: String, detail: String)?
    public init(changed: Bool, element: String, detail: String, refusal: (reason: String, detail: String)?) {
        self.changed = changed; self.element = element; self.detail = detail; self.refusal = refusal
    }
}

public struct QuietProviderKeyOutcome: Sendable {
    public var error: String?
    public var note: String?
    public init(error: String?, note: String?) { self.error = error; self.note = note }
}

public struct QuietToolPage: Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public init(id: String, title: String, summary: String) {
        self.id = id; self.title = title; self.summary = summary
    }
}

@MainActor public protocol QuietToolPresentationPort: Sendable {
    var pages: [QuietToolPage] { get }
    var currentPage: QuietToolPage? { get }
    var composerVerbs: [String] { get }
    func page(named: String) -> QuietToolPage?
    func contextReceiptRead(input: [String: JSONValue]) async -> JSONValue
    func agentViewRead(input: [String: JSONValue]) async -> JSONValue
    func pageScreenshot(input: [String: JSONValue]) async -> JSONValue
}

/// Adapter to the existing interaction transaction owner (C2). No second inbox
/// or continuation state is kept by the tool runtime.
@MainActor public protocol ToolInteractionResolving: Sendable {
    func interaction(id: String, sessionID: String, dataRoot: URL) async -> InlineInteraction?
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
    func saveConnectorToken(_ value: String, connector: String, dataRoot: URL) async -> String?
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
