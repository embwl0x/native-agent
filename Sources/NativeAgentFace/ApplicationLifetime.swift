import AppKit
import Foundation
import NativeAgentShared
import Observation
import SwiftUI
// Blueprint: | `ApplicationLifetime.swift` | Scene mounting and navigation; the window follows attention and learns which pages the person takes back |

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
    /// The page the agent's last quiet move is landing on, until the scene shows it.
    @ObservationIgnored private var agentLanding: String?
    /// How many times the person has brought the window to a page, so a turn can tell whether the person took the window during it.
    @ObservationIgnored private(set) var personMoves = 0

    var visiblePageInput: [String: PartFace.Value]? { mounted?.input() }

    /// The window shows another page. The page the agent's own move brought it to is the agent's; any other is the person's.
    /// Whatever brought the person's page back (the rail, a menu, a shortcut, the palette), its coming back is what the window learns from.
    func sceneShown() {
        if visiblePageInput == agentShown || (agentLanding != nil && visiblePageID == agentLanding) {
            agentShown = nil; agentLanding = nil
        } else {
            personMoves += 1
            FaceFollows.shared.personShowed(visiblePageID)
        }
    }
    /// The person chose a place or a tab, which counts even when the page shown stays the same.
    func personChose() { personMoves += 1 }
    var visiblePageID: String? {
        guard case .string(let page)? = visiblePageInput?["page"] else { return nil }
        return page
    }
    var currentPage: QuietPage? { visiblePageID.flatMap { QuietPages.page(named: $0) } }

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
    func navigate(_ request: FaceNavigationRequest, wanted: @MainActor () -> Bool = { true },
                  followed: (@MainActor (String?, String?) -> Void)? = nil) async throws -> FaceReply {
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
            let origin = visiblePageID
            let delivered = deliverQuietly(destination)
            if delivered {
                // The scene mounts the page after this returns: the move names where it is going, never what is still on screen.
                agentShown = visiblePageInput
                agentLanding = shown.page
                // Her own page show and the window's follow are one thing, the window following her attention: either begins the turn's trial.
                if let followed { followed(origin, shown.page) } else { FaceFollows.shared.agentMoved(from: origin, to: shown.page) }
            }
            if delivered, let tab, let item { ShellRailTabStore.shared.set(tab, for: item) }
            if delivered, let diagnosticsRun { appModel.diagnosticsRunID = diagnosticsRun }
            FaceReports.shared.sceneChanged()
            return .navigation(.init(disposition: delivered ? .mounted : .unavailable, destination: shown,
                                     reason: delivered ? nil : "The main scene is not mounted."))
        }
        let origin = visiblePageID
        let receipt = self.request(destination)
        if receipt == .deliveredToMountedScene {
            agentShown = visiblePageInput
            agentLanding = shown.page
            FaceFollows.shared.agentMoved(from: origin, to: shown.page)
        }
        if let tab, let item { ShellRailTabStore.shared.set(tab, for: item) }
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
/// It learns from what follows its move: the first move a turn makes away from the person's page is one trial, settled when the person
/// deliberately chooses that page again (took it back) or when the turn ends (kept); typing voids it. Pages where taking it back stands
/// (`window.leaves`, from the body's record) count as the person's from the start of the turn, except a sampled turn now and then
/// (`window.sampling`) that follows anyway, so a page the person stops taking back comes back.
@MainActor final class FaceFollows {
    static let shared = FaceFollows()
    private var turn: String?
    private var followed: Set<String> = []
    private var personMovesAtStart = 0
    private var taken = false
    private var beganInChat = false
    private var moved = false
    private var moving = false
    private var trial: (origin: String, landing: String)?
    /// One draw a turn against a left page's sampling chance, so the window's choice holds for the whole turn.
    private var draw = Double.random(in: 0..<1)
    /// The move still to make and the turn it belongs to; it lands only while that turn is the window's and the person has not taken it.
    private var owed: (destination: FaceDestination, turn: String?, observe: Bool)?

    func receive(_ attention: FaceAttention, appModel: AppModel) {
        if attention.turn != turn {
            settle(.kept)
            let backToChat = turn != nil && moved && beganInChat && allowsMove(appModel)
            turn = attention.turn
            followed = []
            taken = false
            moved = false
            personMovesAtStart = ApplicationLifetime.shared.personMoves
            draw = Double.random(in: 0..<1)
            let inChat = ApplicationLifetime.shared.currentPage?.item == .chat
            if backToChat, !inChat {
                go(.init(page: "chat", item: nil, session: nil, message: nil), for: turn, observe: false, appModel: appModel)
            }
            // A turn that begins while the window goes back to Chat begins in Chat.
            beganInChat = inChat || backToChat
        }
        guard turn != nil, let link = attention.link, !followed.contains(link),
              case .page(let page, let item)? = FaceLink(link) else { return }
        followed.insert(link)
        guard allowsMove(appModel) else { return }
        moved = true
        go(.init(page: page, item: item, session: nil, message: nil), for: turn, observe: true, appModel: appModel)
    }

    /// Her own show moved the window during a turn: the same trial a follow begins, once a turn, unless the person already took the window.
    func agentMoved(from origin: String?, to landing: String?) {
        guard turn != nil, trial == nil, !personTook(), let origin, let landing, origin != landing else { return }
        trial = (origin, landing)
    }

    /// The person's own page came back into view during the turn after the window had left it: the person took it back.
    func personShowed(_ page: String?) {
        if let page, trial?.origin == page { settle(.tookBack) }
    }

    private func settle(_ outcome: FollowOutcome) {
        guard let trial else { return }
        self.trial = nil
        FaceReports.shared.submit(.followSettled(origin: trial.origin, landing: trial.landing, outcome: outcome))
    }

    /// The person wrote in the composer or an ask bar: during a turn, the window is the person's for the rest of it.
    func personTyped() {
        if turn != nil {
            trial = nil
            taken = true
        }
    }

    /// Whether the person has taken the window this turn: typed, or brought the window to a page or chose a place or tab since it began.
    private func personTook() -> Bool {
        if !taken { taken = ApplicationLifetime.shared.personMoves != personMovesAtStart }
        return taken
    }

    private func allowsMove(_ appModel: AppModel) -> Bool {
        guard appModel.facePreference(WindowFollowsPreference.key, as: Bool.self) == true, !personTook() else { return false }
        if let page = ApplicationLifetime.shared.visiblePageID, appModel.windowLeaves.contains(page),
           draw >= appModel.windowSampling[page] ?? 0 { taken = true }
        return !taken
    }

    private func go(_ destination: FaceDestination, for owner: String?, observe: Bool, appModel: AppModel) {
        owed = (destination, owner, observe)
        guard !moving else { return }
        moving = true
        Task { @MainActor [self] in
            while let next = owed {
                owed = nil
                @MainActor func wanted() -> Bool { next.turn == self.turn && self.allowsMove(appModel) }
                guard wanted() else { continue }
                do {
                    _ = try await ApplicationLifetime.shared.navigate(.init(destination: next.destination, policy: .quiet),
                        wanted: wanted, followed: { origin, landing in
                            if next.observe, self.trial == nil, let origin, let landing, origin != landing {
                                self.trial = (origin, landing)
                            }
                        })
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
