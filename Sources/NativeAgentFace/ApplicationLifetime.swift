import AppKit
import Foundation
import NativeAgentShared
import Observation
// Blueprint: | `ApplicationLifetime.swift` | Renderer-owned scene mounting, command admission and acknowledged navigation |

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

    var visiblePageInput: [String: PartFace.Value]? { mounted?.input() }
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
    func navigate(_ request: FaceNavigationRequest) async throws -> FaceReply {
        let target = request.destination
        guard let appModel else { throw FaceWireError.disconnected }
        if let session = target.session {
            try FaceWindowReply.check(await appModel.client.act(.selectConversation(session: session, userInitiated: false)))
            appModel.activeChatSessionId = session
            appModel.pendingChatMessageID = target.message
        }
        let destination: NativeAgentNavigationDestination
        var tab: String?
        var item: SidebarItem?
        var diagnosticsRun: String?
        if target.session != nil { destination = .sidebar(.chat) }
        else if target.page == "approvals" { destination = .activity(.approvals) }
        else if target.page == "today_inbox" { destination = .activity(.inbox) }
        else if target.page == "memory_proposals" { destination = .activity(.memoryProposals) }
        else if let page = QuietPages.page(named: target.page) {
            destination = page.item == .ownPage ? .ownPage(page.id) : .sidebar(page.item)
            item = SidebarItem.shellHome(for: page.item)?.parent ?? page.item
            tab = SidebarItem.shellHome(for: page.item)?.tab
            if let handle = target.item, !handle.isEmpty, let item {
                if item == .desk {
                    _ = try await appModel.client.act(.deskCommand(.init(command: "validate", handle: handle, arguments: [:]))).checkedValue()
                    appModel.pendingDeskHandle = handle
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
                        } else {
                            throw PartCallError(code: "page_item_unavailable", message: "This page has no current item named " + handle + ".")
                        }
                    }
                }
            }
        } else {
            throw PartCallError(code: "page_unavailable", message: "The requested page is absent from my current face.")
        }
        if request.policy == .quiet {
            let delivered = deliverQuietly(destination)
            if delivered, let tab, let item { UserDefaults.standard.set(tab, forKey: ShellRailTab.storageKey(item)) }
            if delivered, let diagnosticsRun { appModel.diagnosticsRunID = diagnosticsRun }
            FaceReports.shared.sceneChanged()
            return .navigation(.init(disposition: delivered ? .mounted : .unavailable, destination: target,
                                     reason: delivered ? nil : "The main scene is not mounted."))
        }
        let receipt = self.request(destination)
        if let tab, let item { UserDefaults.standard.set(tab, forKey: ShellRailTab.storageKey(item)) }
        if let diagnosticsRun { appModel.diagnosticsRunID = diagnosticsRun }
        return .navigation(.init(disposition: receipt == .deliveredToMountedScene ? .mounted : .queued,
                                 destination: target, reason: nil))
    }
    func showWindow(destination: FaceDestination?) async throws -> FaceReply {
        if let openMainWindow { openMainWindow() } else { windowOwed = true }
        NSApp.activate()
        if let destination { return try await navigate(.init(destination: destination, policy: .foreground)) }
        return .acknowledged
    }
}
