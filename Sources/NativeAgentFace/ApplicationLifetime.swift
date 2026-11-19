import AppKit
import Foundation
import NativeAgentShared
import Observation
import SwiftUI
// Blueprint: | `ApplicationLifetime.swift` | Scene mounting, command admission and acknowledged navigation; the window follows the turn's attention |

enum NativeAgentNavigationDestination: Equatable, Sendable {
    case sidebar(SidebarItem)
    case ownPage(String)
    case activity(ActivitySection)
    case chatShortcut(ChatSlashPage)
    case savedThing(PaletteSavedDestination)

    static func route(_ raw: String?) -> Self? {
        guard let raw else { return nil }
        let name = AppDoorNames.resolve(raw.replacingOccurrences(of: "sidebar:", with: ""))
        if name == "inbox" { return .sidebar(.inboxPolicy) }
        guard let page = QuietPages.all.first(where: { $0.id == name }) else { return nil }
        return .sidebar(page.item)
    }
}

enum NativeAgentNavigationRequestReceipt { case deliveredToMountedScene, queuedForMainScene }

@MainActor @Observable
final class ApplicationLifetime {
    static let shared = ApplicationLifetime()
    static let mainSceneID = "main"
    var appModel: AppModel?
    @ObservationIgnored private var openMainWindow: (() -> Void)?
    /// The body asked for the window before the opener mounted; it opens as soon as there is one.
    @ObservationIgnored private var windowOwed = false
    @ObservationIgnored private var pending: [NativeAgentNavigationDestination] = []
    @ObservationIgnored private var mounted: (id: UUID, input: () -> [String: PartFace.Value]?,
        replayTour: () -> Void, deliver: (NativeAgentNavigationDestination) -> Void)?
    /// The page the window showed right after the agent last moved it; the window coming to any other page was the person's choice.
    @ObservationIgnored private var agentShown: [String: PartFace.Value]?
    /// How many times the person has brought the window to a page, so a turn can tell whether the person took the window during it.
    @ObservationIgnored private(set) var personMoves = 0

    var visiblePageInput: [String: PartFace.Value]? { mounted?.input() }

    /// The window shows another page. The page the agent's own move brought it to is the agent's; any other is the person's.
    func sceneShown() {
        if visiblePageInput == agentShown { agentShown = nil } else { personMoves += 1 }
    }
    /// The person chose a place or a tab, which counts even when the page shown stays the same.
    func personChose() { personMoves += 1 }
    var currentPage: QuietPage? {
        guard case .string(let page)? = visiblePageInput?["page"] else { return nil }
        return QuietPages.page(named: page)
    }

    func configureMainWindowOpening(_ open: @escaping @MainActor () -> Void) {
        // The opener is set again each time Commands re-evaluate, which must not bring the window forward over a detached chat.
        let mounting = openMainWindow == nil
        openMainWindow = open
        guard windowOwed || (mounting && (!pending.isEmpty || appModel?.windowActions.isEmpty == false)) else { return }
        windowOwed = false
        // This runs while SwiftUI evaluates a body, which must not open a window.
        Task { @MainActor in open() }
    }
    func mountMainScene(visiblePageInput: @escaping () -> [String: PartFace.Value]? = { nil },
                        replayTour: @escaping () -> Void,
                        deliver: @escaping (NativeAgentNavigationDestination) -> Void) -> UUID {
        let id = UUID()
        mounted = (id, visiblePageInput, replayTour, deliver)
        drain()
        FaceReports.shared.sceneChanged()
        return id
    }
    func unmountMainScene(id: UUID) {
        if mounted?.id == id {
            mounted = nil
            if let connection = FaceReports.shared.connectionID {
                FaceReports.shared.submit(.reportScene(.init(connection: connection, id: id, destination: nil, isKey: false,
                    composerSession: nil, selectedSession: nil, mounted: false)))
            }
        }
    }
    @discardableResult func request(_ destination: NativeAgentNavigationDestination) -> NativeAgentNavigationRequestReceipt {
        pending.append(destination)
        activateMainWindow()
        guard mounted != nil else { return .queuedForMainScene }
        drain()
        return .deliveredToMountedScene
    }
    func activateMainWindow() {
        NSApp.activate()
        openMainWindow?()
    }
    func deliverQuietly(_ destination: NativeAgentNavigationDestination) -> Bool {
        guard let mounted else { return false }
        mounted.deliver(destination)
        return true
    }
    private func drain() {
        guard let mounted else { return }
        let destinations = pending
        pending.removeAll()
        for destination in destinations { mounted.deliver(destination) }
        FaceReports.shared.sceneChanged()
    }
    var scene: SceneReport? {
        guard let mounted, let connection = FaceReports.shared.connectionID else { return nil }
        let destination: FaceDestination?
        if case .string(let page)? = visiblePageInput?["page"] {
            let item: String?
            if case .string(let value)? = visiblePageInput?["item"] { item = value } else { item = nil }
            destination = .init(page: page, item: item, session: nil, message: nil)
        } else { destination = nil }
        return .init(connection: connection, id: mounted.id, destination: destination, isKey: NSApp.keyWindow != nil,
                     composerSession: QuietSelfAdmin.shared.composerCards == nil ? nil : appModel?.activeChatSessionId,
                     selectedSession: appModel?.activeChatSessionId, mounted: true)
    }
    func sceneReport() throws -> SceneReport {
        guard let scene else { throw PartCallError(code: "scene_unmounted", message: "The main scene is not mounted.") }
        return scene
    }
    func replayTour() throws {
        guard let mounted else { throw PartCallError(code: "scene_unmounted", message: "Open the main window before replaying its tour.") }
        mounted.replayTour()
    }
    /// `wanted` is asked again after every wait and before anything moves: a move nobody wants any more changes nothing.
    func navigate(_ request: FaceNavigationRequest, wanted: @MainActor () -> Bool = { true }) async throws -> FaceReply {
        let target = request.destination
        guard let appModel else { throw FaceWireError.disconnected }
        func stillWanted() throws {
            guard wanted() else { throw PartCallError(code: "navigation_overtaken", message: "The window was taken before this move landed.") }
        }
        if let session = target.session {
            try FaceWindowReply.check(await appModel.client.act(.selectConversation(session: session, userInitiated: false)))
            appModel.chatSelectionGeneration = UUID()
            appModel.commitChatSessionSelection(session)
            appModel.pendingChatMessageID = target.message
        }
        let destination: NativeAgentNavigationDestination
        var tab: String?
        var item: SidebarItem?
        var diagnosticsRun: String?
        // The receipt names the page the window resolved, so the caller reads what is shown without resolving the name again.
        var shown = target
        if target.session != nil { destination = .sidebar(.chat) }
        else if target.page == "approvals" { destination = .activity(.approvals) }
        else if target.page == "today_inbox" { destination = .activity(.inbox) }
        else if target.page == "memory_proposals" { destination = .activity(.memoryProposals) }
        // A page by its name, or a place by the word the rail draws for it, which opens on the page that place opens first.
        else if let page = QuietPages.page(named: target.page)
            ?? ShellSurface.named(target.page, appModel: appModel).flatMap({ QuietPages.shown($0.firstPage) }) {
            destination = page.item == .ownPage ? .ownPage(page.id) : .sidebar(page.item)
            shown = .init(page: page.id, item: target.item, session: nil, message: nil)
            item = SidebarItem.shellHome(for: page.item)?.parent ?? page.item
            tab = SidebarItem.shellHome(for: page.item)?.tab
            if let handle = target.item, !handle.isEmpty, let item {
                if item == .desk {
                    // Showing an item opens it, as its row does: the Desk's owner selects it, and the page draws it open.
                    // Selecting is an act, answered as one: only its failure or refusal stops the show.
                    try stillWanted()
                    switch try await appModel.client.act(.deskCommand(.init(command: "select", handle: handle, arguments: [:]))) {
                    case .failed(let failure), .refused(let failure): throw failure
                    default: break
                    }
                }
                else if item == .memories, let memory = MemoriesFaceTarget(row: handle) {
                    appModel.pendingMemoryFaceTarget = .init(page: "memories", item: memory.row, session: nil, message: nil)
                    tab = "memories"
                } else {
                    let tabs = appModel.shellLayout.map { ShellRailTab.all($0).first { $0.page == item }?.tabs ?? [] } ?? []
                    let destinations = item == .personality ? PersonalityFaceDestinations.tabs : []
                    if let match = (tabs + destinations).first(where: {
                        $0.key.caseInsensitiveCompare(handle) == .orderedSame || $0.title.caseInsensitiveCompare(handle) == .orderedSame
                    }) {
                        tab = match.key
                    } else {
                        if item == .diagnostics {
                            _ = try await appModel.client.act(.readRun(id: handle)).checkedValue()
                            diagnosticsRun = handle
                            tab = "diagnostics"
                        } else if item == .memories {
                            // Any other item on Memories is a memory by its id, the id a recall names it by.
                            appModel.pendingMemoryFaceTarget = .init(page: "memories", item: MemoriesFaceTarget.memory(handle).row,
                                                                     session: nil, message: nil)
                            tab = "memories"
                        } else {
                            throw PartCallError(code: "page_item_unavailable", message: "This page has no current item named " + handle + ".")
                        }
                    }
                }
            }
        } else {
            throw PartCallError(code: "page_unavailable", message: "The requested page is absent from my current face.")
        }
        try stillWanted()
        if request.policy == .quiet {
            let delivered = deliverQuietly(destination)
            if delivered { agentShown = visiblePageInput }
            if delivered, let tab, let item { UserDefaults.standard.set(tab, forKey: ShellRailTab.storageKey(item)) }
            if delivered, let diagnosticsRun { appModel.diagnosticsRunID = diagnosticsRun }
            FaceReports.shared.sceneChanged()
            return .navigation(.init(disposition: delivered ? .mounted : .unavailable, destination: shown,
                                     reason: delivered ? nil : "The main scene is not mounted."))
        }
        let receipt = self.request(destination)
        if receipt == .deliveredToMountedScene { agentShown = visiblePageInput }
        if let tab, let item { UserDefaults.standard.set(tab, forKey: ShellRailTab.storageKey(item)) }
        if let diagnosticsRun { appModel.diagnosticsRunID = diagnosticsRun }
        return .navigation(.init(disposition: receipt == .deliveredToMountedScene ? .mounted : .queued,
                                 destination: shown, reason: nil))
    }
    func showWindow(destination: FaceDestination?) async throws -> FaceReply {
        if let openMainWindow { openMainWindow() } else { windowOwed = true }
        NSApp.activate()
        if let destination { return try await navigate(.init(destination: destination, policy: .foreground)) }
        return .acknowledged
    }
}

/// The window is the agent's face, so it shows where the running turn's attention is (`TurnFace.nowOn`): each place once a turn, quietly,
/// never brought to the front, and only while "The window follows me" is on. The record moves at most once a model round (the engine
/// settles it when the model next speaks), and one move runs at a time: a place named while the window moves replaces any still waiting.
/// The person outranks it: once the person brings the window to a page, chooses a place or a tab, or types in the composer or an ask bar
/// during a turn, the window stays where the person has it for the rest of that turn, and a move already on its way lands nowhere. When
/// the turn ends the window stays, unless the turn began in Chat and the person never took the window: then it returns to Chat.
@MainActor final class FaceFollows {
    static let shared = FaceFollows()
    private var turn: String?
    private var followed: Set<String> = []
    private var personMovesAtStart = 0
    private var taken = false
    private var beganInChat = false
    private var moved = false
    private var moving = false
    /// The move still to make and the turn it belongs to; it lands only while that turn is the window's and the person has not taken it.
    private var owed: (destination: FaceDestination, turn: String?)?

    func receive(_ attention: FaceAttention, appModel: AppModel) {
        if attention.turn != turn {
            let backToChat = turn != nil && moved && beganInChat && !personTook()
            turn = attention.turn
            followed = []
            taken = false
            moved = false
            personMovesAtStart = ApplicationLifetime.shared.personMoves
            let inChat = ApplicationLifetime.shared.currentPage?.item == .chat
            if backToChat, !inChat { go(.init(page: "chat", item: nil, session: nil, message: nil), for: turn) }
            // A turn that begins while the window goes back to Chat begins in Chat.
            beganInChat = inChat || backToChat
        }
        guard turn != nil, let link = attention.link, !followed.contains(link),
              case .page(let page, let item)? = FaceLink(link) else { return }
        followed.insert(link)
        guard appModel.facePreference(WindowFollowsPreference.key, as: Bool.self) == true, !personTook() else { return }
        moved = true
        go(.init(page: page, item: item, session: nil, message: nil), for: turn)
    }

    /// The person wrote in the composer or an ask bar: during a turn, the window is the person's for the rest of it.
    func personTyped() {
        if turn != nil { taken = true }
    }

    /// Whether the person has taken the window this turn: typed, or brought the window to a page or chose a place or tab since it began.
    private func personTook() -> Bool {
        if !taken { taken = ApplicationLifetime.shared.personMoves != personMovesAtStart }
        return taken
    }

    private func wants(_ owner: String?) -> Bool { owner == turn && !personTook() }

    private func go(_ destination: FaceDestination, for owner: String?) {
        owed = (destination, owner)
        guard !moving else { return }
        moving = true
        Task { @MainActor [self] in
            while let next = owed {
                owed = nil
                guard wants(next.turn) else { continue }
                do {
                    _ = try await ApplicationLifetime.shared.navigate(.init(destination: next.destination, policy: .quiet),
                                                                     wanted: { self.wants(next.turn) })
                } catch {
                    ApplicationLifetime.shared.appModel?.setFailureStatus(error, action: "follow the turn's attention")
                }
            }
            moving = false
        }
    }
}

/// One conversation's turn and where its attention is, as the window reads it from the turn's face.
struct FaceAttention: Equatable {
    let turn: String?
    let link: String?
}

/// Next to the Work pane's own watcher: reads the shown conversation's turn and hands its attention to `FaceFollows`.
struct FaceFollowsWatcher: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        // Any door's turn the conversation shows: the Mac's own, the phone's, a resident's.
        let attention = appModel.turnPart("nowOn", for: appModel.activeChatSessionId) {
            FaceAttention(turn: $0?.isRunning == true ? $0?.turnID : nil, link: $0?.nowOn)
        }
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: attention, initial: true) { _, attention in FaceFollows.shared.receive(attention, appModel: appModel) }
    }
}
