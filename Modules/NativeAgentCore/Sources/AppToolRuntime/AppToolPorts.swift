import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ChatOrchestration
import ProviderRouting

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
    /// One `skill_manage` verb, through the Skills and Tools pages' own calls.
    /// `steer` names the peers steering this turn (`PeerDataTaint.carried`).
    func manageSkill(verb: String, input: [String: JSONValue], steer: [String]) async -> (ok: Bool, detail: String, fields: [String: JSONValue])
    /// The `connections` tool's verbs, through the Connectors, Telegram and
    /// MCP pages' own buttons. Core has already refused the raising ones.
    func connections(verb: String, input: [String: JSONValue]) async -> JSONValue
    /// One `provider` verb, through the call the Providers page's button makes.
    func provider(verb: String, input: [String: JSONValue]) async -> JSONValue
}

public struct QuietComposerOutcome: Sendable {
    public var changed: Bool
    public var element: String
    public var detail: String
    public var status: String
    public var refusal: (reason: String, detail: String)?
    public init(changed: Bool, element: String, detail: String, refusal: (reason: String, detail: String)?, status: String = "ok") {
        self.changed = changed; self.element = element; self.detail = detail; self.refusal = refusal; self.status = status
    }
    public static func done(_ element: String, _ detail: String, changed: Bool = true, status: String = "ok") -> Self {
        Self(changed: changed, element: element, detail: detail, refusal: nil, status: status)
    }
    public static func refuse(_ element: String, _ reason: String, _ detail: String) -> Self {
        Self(changed: false, element: element, detail: detail, refusal: (reason, detail))
    }
}

public struct QuietToolPage: Sendable, Equatable {
    public let id: String
    public let title: String
    public let summary: String
    public init(id: String, title: String, summary: String) {
        self.id = id; self.title = title; self.summary = summary
    }

    public static let all: [QuietToolPage] = [
        QuietToolPage(id: "chat", title: "Chat",
                  summary: "Conversations, attachments, voice, sessions, and the agent's name and status. Screen controls are separate from background history: page:chat + item:<conversation id> reads 8 messages or args {limit} up to 16. Resolve with chat.list; chat.search {session_id, sort:newest, limit:12} without query reads older history through next_call; chat.message reads full truncated bodies."),
        QuietToolPage(id: "today", title: "Today",
                  summary: "Notifications, approvals, proposals, recent work, and what is waiting."),
        QuietToolPage(id: "memories", title: "Memories",
                  summary: "Saved facts, pending proposals, and the knowledge graph."),
        QuietToolPage(id: "desk", title: "Desk",
                  summary: "Projects, dependencies, schedules, pursuits, progress and outcomes."),
        QuietToolPage(id: "notifications", title: "Notifications",
                  summary: "The proactive inbox, its triggers, watched folders, and history."),
        QuietToolPage(id: "bots", title: "Helpers",
                  summary: "Standing briefs on a schedule or an event, and their dated replies."),
        QuietToolPage(id: "personality", title: "Personality",
                  summary: "Identity, expression, about-you, growth and working-guideline documents; minds and dreams."),
        QuietToolPage(id: "providers", title: "Providers",
                  summary: "Connected AI accounts and the model each activity group runs on."),
        QuietToolPage(id: "trust", title: "Trust",
                  summary: "Presets, feature permissions, approvals, and Mac integration access."),
        QuietToolPage(id: "connectors", title: "Connectors",
                  summary: "Service connections, with MCP, Telegram and iPhone tabs."),
        QuietToolPage(id: "telegram", title: "Telegram",
                  summary: "Telegram on or off, who may reach the agent, mention-only, its model, test reply and logs."),
        QuietToolPage(id: "mcp", title: "MCP",
                  summary: "MCP servers with Warm, Restart and Refresh, the consents granted, and each server's tools as mcp.<server>.<tool> actions."),
        QuietToolPage(id: "mac_integration", title: "Mac Integration",
                  summary: "Read and write access per Mac app: Calendar, Mail, Messages, Notes and the rest."),
        QuietToolPage(id: "pairing", title: "iPhone pairing",
                  summary: "Paired phones and the iCloud pairing status."),
        QuietToolPage(id: "agents", title: "Agents",
                  summary: "Agent contacts and coding helpers: message, read, connect, stop, recipes, bridge jobs, and Claude's worklog of what she has been doing and working on, newest first."),
        // Each Mac app and connector her actions reach is a page of its own:
        // its access or connection, and its actions. A Mac app's page is
        // where User sets its access (Trust → Mac integration).
        QuietToolPage(id: "mail", title: "Mail",
                  summary: "Apple Mail (every account added to Mail, Gmail included), the separate Gmail API connector and AgentMail: read, search, triage, send and reply."),
        QuietToolPage(id: "calendar", title: "Calendar",
                  summary: "Calendar and Google Calendar: events, free/busy, create, change, delete and invitations."),
        QuietToolPage(id: "reminders", title: "Reminders",
                  summary: "Reminders: due today, search, read, create, update, complete and delete."),
        QuietToolPage(id: "notes", title: "Notes", summary: "Apple Notes: search, create and update."),
        QuietToolPage(id: "contacts", title: "Contacts",
                  summary: "Contacts: search, create or update, and delete."),
        QuietToolPage(id: "messages", title: "Messages", summary: "Messages: recent threads, and send."),
        QuietToolPage(id: "github", title: "GitHub",
                  summary: "Repositories, issues, pull requests, notifications and project tracking."),
        QuietToolPage(id: "slack", title: "Slack", summary: "Slack channels, search and posting."),
        QuietToolPage(id: "notion", title: "Notion", summary: "Notion search and pages."),
        QuietToolPage(id: "x", title: "X",
                  summary: "X (Twitter): your account, search, timeline and a user's posts."),
        QuietToolPage(id: "markets", title: "Markets",
                  summary: "Quotes and watchlists, TradingView's among them."),
        // Her hands on the Mac and the web. Files, the shell and the browser
        // are Trust's to allow; the web's search is the SearXNG MCP server.
        QuietToolPage(id: "files", title: "Files",
                  summary: "Read, list, search, excerpt and write files; apply a patch; Spotlight."),
        QuietToolPage(id: "shell", title: "Shell",
                  summary: "Shell commands, git, Swift builds and tests, remote nodes, and restarting or installing the app."),
        QuietToolPage(id: "web", title: "Web",
                  summary: "Read a public page privately, and search or fetch the web with SearXNG."),
        QuietToolPage(id: "browser", title: "Browser",
                  summary: "The NativeAgent browser and your own Chrome tab: open, read, links, screenshots, clicks and forms."),
        // Her hands on the Mac itself: Full Mac's accessibility category is
        // Trust's to allow; Music's access is Mac integration's.
        QuietToolPage(id: "mac", title: "Mac",
                  summary: "The live screen: look, act by name, go to an app, file or URL, wait, read a document, menus, the clipboard, system info and app activity."),
        QuietToolPage(id: "music", title: "Music",
                  summary: "Apple Music: what's playing, play, pause or skip, search the library, tracks and playlists."),
        QuietToolPage(id: "capabilities", title: "Capabilities",
                  summary: "What the agent can actually do, action by action."),
        QuietToolPage(id: "diagnostics", title: "Diagnostics",
                  summary: "Doctor, Status, Runs log, Cognition and Inspector."),
        QuietToolPage(id: "skills", title: "Skills",
                  summary: "Installed skills: read, run, write and manage them."),
        QuietToolPage(id: "tools", title: "Tools",
                  summary: "Available tools, their access, and tools the agent wrote."),
        QuietToolPage(id: "settings", title: "Settings",
                  summary: "Appearance, shortcuts, updates, and the switches for an inner life, dreams and memory."),
    ]


    public static var ids: [String] { all.map(\.id) }

    public static func page(named raw: String) -> QuietToolPage? {
        let key = AppDoorNames.resolve(raw)
        return all.first { $0.id == key }
    }
}

@MainActor public protocol QuietToolPresentationPort: Sendable {
    var pages: [QuietToolPage] { get }
    var currentPage: QuietToolPage? { get }
    func page(named: String) -> QuietToolPage?
    func contextReceiptRead(input: [String: JSONValue]) async -> JSONValue
    func agentViewRead(input: [String: JSONValue]) async -> JSONValue
    func pageScreenshot(input: [String: JSONValue]) async -> JSONValue
}

/// Adapter to the existing interaction transaction owner (C2). No second inbox
/// or continuation state is kept by the tool runtime.
@MainActor public protocol ToolInteractionResolving: Sendable {
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
