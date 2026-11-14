import AppKit
import Foundation
import NativeAgentShared
import SwiftUI
// Blueprint: | `QuietSelfAdminRender.swift` | Offscreen bitmap drawing, local page routing and composer presentation |

extension EnvironmentValues {
    /// Captures draw prepared values without starting owner work.
    @Entry var quietOffscreenRead: Bool = false

    /// A nil screenshot tab selects the page default without changing the mounted selection.
    @Entry var quietRailTab: String? = nil
    @Entry var quietTranscriptReader: UUID? = nil
    @Entry var quietCaptureSession: QuietCaptureSession? = nil
}

private struct LiveTaskModifier<ID: Equatable>: ViewModifier {
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    let id: ID
    let action: @Sendable () async -> Void

    func body(content: Content) -> some View {
        content.task(id: id) {
            guard !quietOffscreenRead else { return }
            await action()
        }
    }
}
private struct LiveAppearModifier: ViewModifier {
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onAppear {
            guard !quietOffscreenRead else { return }
            action()
        }
    }
}
extension View {
    /// Suppress lifecycle work and writes for offscreen screenshots.
    func liveTask(
        @_inheritActorContext _ action: @escaping @Sendable () async -> Void
    ) -> some View {
        modifier(LiveTaskModifier(id: 0, action: action))
    }

    func liveTask<ID: Equatable>(
        id: ID,
        @_inheritActorContext _ action: @escaping @Sendable () async -> Void
    ) -> some View {
        modifier(LiveTaskModifier(id: id, action: action))
    }

    /// Suppress appearance side effects for offscreen screenshots.
    func liveOnAppear(_ action: @escaping () -> Void) -> some View {
        modifier(LiveAppearModifier(action: action))
    }

    /// Owner reads run only in mounted pages; captures consume their prepared frame.
    func quietReadTask(
        live: Bool = true,
        @_inheritActorContext _ action: @escaping @Sendable () async -> Void
    ) -> some View {
        modifier(QuietReadTaskModifier(id: 0, live: live, action: action))
    }

    func quietReadTask<ID: Equatable>(
        id: ID,
        live: Bool = true,
        @_inheritActorContext _ action: @escaping @Sendable () async -> Void
    ) -> some View {
        modifier(QuietReadTaskModifier(id: id, live: live, action: action))
    }
}

private struct QuietReadTaskModifier<ID: Equatable>: ViewModifier {
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    let id: ID
    let live: Bool
    let action: @Sendable () async -> Void
    func body(content: Content) -> some View {
        content.task(id: id) {
            guard !quietOffscreenRead, live else { return }
            await action()
        }
    }
}

@MainActor
enum QuietSelfAdminRender {
    /// Preserve wide layouts while keeping a PNG within the eight-MiB tool-image ceiling.
    static let defaultSize = CGSize(width: 1280, height: 860)

    // MARK: - The page, built offscreen

    /// A nil tab draws the page default without changing the mounted tab.
    @ViewBuilder
    static func pageView(for page: QuietPage, tab: String? = nil, appModel: AppModel, size: CGSize = defaultSize) -> some View {
        // Render tab destinations inside their rail frame so screenshots match the visible page.
        Group {
            if QuietPages.drawOnly.contains(page) {
                // A picture changes no selection: Simple is drawn on Chat, or on Control's Settings tab, where Simple's settings live.
                SimpleShellView(shown: page.id == QuietPages.simpleSettings ? .item(.settings) : .item(.chat),
                                choose: { _, _ in }, select: { _ in })
            } else {
                ShellPageContent(item: page.item, ownPage: page.item == .ownPage ? page.id : nil)
            }
        }
        .environment(\.quietRailTab, tab ?? SidebarItem.shellHome(for: page.item)?.tab)
        .environment(appModel)
        // A screenshot is a read, so lifecycle work must not change the state being captured.
        .environment(\.quietOffscreenRead, true)
        .environment(\.faceHoldsDocuments, false)
        .macFaceStyle()
        .frame(width: size.width, height: size.height)
        // Supply the same room colour as the onscreen ShellSheet.
        .background(NativeAgentShell.room.ignoresSafeArea())
    }

    /// The body prepares data and the router supplies its actual applied-frame receipt.
    static func renderPage(_ request: PageRenderRequest, appModel: AppModel,
                           appliedEpoch: UUID, appliedBarrier: UUID) async throws -> PageRenderResult {
        guard request.epoch == appliedEpoch, request.barrier == appliedBarrier else {
            throw PartCallError(code: "render_frame_unapplied", message: "The requested page frame has not been applied.")
        }
        guard request.width.isFinite, request.height.isFinite,
              let width = Int(exactly: request.width.rounded(.down)), width > 0,
              let height = Int(exactly: request.height.rounded(.down)), height > 0 else {
            throw PartCallError(code: "render_size_invalid", message: "Page dimensions must be finite positive pixel counts.")
        }
        guard let page = QuietPages.page(named: request.page) ?? QuietPages.drawOnly.first(where: { $0.id == request.page }) else {
            throw PartCallError(code: "render_page_unavailable", message: "The requested page is absent from this applied frame.")
        }
        try requirePrepared(page: page, tab: request.tab, appModel: appModel)
        if page.item == .chat {
            let session = appModel.activeChatSessionId
            guard appModel.face.slot(.transcript(session: session)).value(as: TranscriptFace.self)?.readers[request.reader] != nil else {
                throw PartCallError(code: "render_reader_unavailable", message: "The selected conversation has no matching prepared capture reader.")
            }
        }
        let size = CGSize(width: width, height: height)
        let drawsPane = page.item == .chat && !QuietPages.drawOnly.contains(page)
        if drawsPane {
            guard request.workPane == WorkPaneState.shared.snapshot(appModel: appModel) else {
                throw QuietCaptureSession.failure("The requested Work pane selection is not the window's current selection.")
            }
        }
        let capture = QuietCaptureSession(pane: drawsPane ? request.workPane : nil,
            session: page.item == .chat ? appModel.activeChatSessionId : nil, reader: request.reader,
            page: page.item == .chat ? nil : ShellPageContent.doorPage(page.item) ?? page.id)
        defer { capture.close() }
        return try await withTaskCancellationHandler {
            try await capture.prepare(appModel: appModel, size: size)
            return try await draw(request, page: page, appModel: appModel, size: size, capture: capture,
                appliedEpoch: appliedEpoch, appliedBarrier: appliedBarrier, width: width, height: height)
        } onCancel: { Task { @MainActor in capture.close() } }
    }

    private static func draw(_ request: PageRenderRequest, page: QuietPage, appModel: AppModel, size: CGSize,
                             capture: QuietCaptureSession, appliedEpoch: UUID, appliedBarrier: UUID,
                             width: Int, height: Int) async throws -> PageRenderResult {
        let hosting = NSHostingView(rootView: AnyView(
            pageView(for: page, tab: request.tab, appModel: appModel, size: size)
                .environment(\.quietTranscriptReader, request.reader)
                .environment(\.quietCaptureSession, capture)
                .transaction { $0.animation = nil }
                .environment(\.appearsActive, true)
        ))
        hosting.frame = CGRect(origin: .zero, size: size)
        let host = QuietCaptureWindow(contentRect: CGRect(origin: .zero, size: size),
                                      styleMask: [.borderless], backing: .buffered, defer: true)
        host.isReleasedWhenClosed = false
        host.contentView = hosting
        defer { host.contentView = nil; host.close() }
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let webImages = try await capture.images(in: hosting)
        try capture.validate(appModel: appModel)
        try Task.checkCancellation()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw PartCallError(code: "render_allocation_failed", message: "The page bitmap could not be allocated.")
        }
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        if !webImages.isEmpty {
            guard let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
                throw QuietCaptureSession.failure("The native page bitmap has no drawing context.")
            }
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = graphics
            for (frame, image) in webImages {
                let rect = CGRect(x: frame.minX, y: hosting.isFlipped ? size.height - frame.maxY : frame.minY,
                    width: frame.width, height: frame.height)
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw PartCallError(code: "render_encoding_failed", message: "The page bitmap could not be encoded as PNG.")
        }
        return PageRenderResult(png: png, pixelWidth: bitmap.pixelsWide, pixelHeight: bitmap.pixelsHigh,
                                epoch: appliedEpoch, appliedBarrier: appliedBarrier, failure: nil)
    }

    private static func requirePrepared(page: QuietPage, tab: String?, appModel: AppModel) throws {
        guard let layout = appModel.shellLayout else {
            throw PartCallError(code: "render_layout_unavailable", message: "The capture frame has no layout reading.")
        }
        _ = try layout.get()
        if page.item == .diagnostics, let tab,
           ShellRailTab.all(layout).first(where: { $0.page == .diagnostics })?.tabs.contains(where: { $0.key == tab }) != true {
            throw PartCallError(code: "capture_tab_unavailable", message: "This Diagnostics tab is absent from the applied layout.")
        }
        var present = appModel.face.slot(.settings).value(as: SettingsFace.self) != nil
        if page.item == .chat {
            present = present && appModel.face.slot(.sessions).value(as: SessionListFace.self) != nil
                && appModel.face.slot(.sessionNavigation).value(as: SessionNavigationFace.self) != nil
        } else {
            let owner = ShellPageContent.doorPage(page.item) ?? page.id
            present = present && appModel.face.slot(.page(owner)).value(as: PartFaceSnapshot.self) != nil
        }
        switch (page.item, tab) {
        case (.memories, "knowledge"):
            present = present && appModel.face.slot(.knowledgeGraph).value(as: KnowledgeGraphFace.self) != nil
                && appModel.face.slot(.page("knowledge")).value(as: PartFaceSnapshot.self) != nil
        case (.personality, "documents"):
            present = present && appModel.face.slot(.onboarding).value(as: OnboardingFace.self)?.state == .ready
        case (.personality, "dreams"):
            present = present && appModel.face.slot(.page("dreams")).value(as: PartFaceSnapshot.self) != nil
        case (.diagnostics, "Cognition"):
            present = present && appModel.face.slot(.page("cognition")).value(as: PartFaceSnapshot.self) != nil
                && appModel.face.slot(.contextFlowHealth).value(as: ContextFlowHealthFace.self) != nil
                && appModel.face.slot(.deskDiagnostics).value(as: DeskDiagnosticsFace.self) != nil
        case (.memories, "upkeep"):
            present = present && appModel.face.slot(.page("memory-upkeep")).value(as: PartFaceSnapshot.self) != nil
        case (.diagnostics, "Inspector"):
            present = present && appModel.face.slot(.inspector(after: nil)).value(as: InspectorFace.self) != nil
        default: break
        }
        if QuietPages.drawOnly.contains(page) {
            present = present && appModel.face.slot(.contacts).value(as: ContactsFace.self) != nil
                && appModel.face.slot(.helpers).value(as: HelpersFace.self) != nil
        }
        if page.id == QuietPages.simpleSettings {
            present = present && appModel.face.slot(.page("settings")).value(as: PartFaceSnapshot.self) != nil
        }
        guard present else {
            throw PartCallError(code: "render_data_unprepared", message: "The requested native page has no complete prepared capture frame.")
        }
    }

    /// Answer as key for control accents without ordering the window in or taking focus.
    private final class QuietCaptureWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
    }

}

@MainActor
final class QuietSelfAdmin {
    static let shared = QuietSelfAdmin()

    /// Drafts belong to AppModel by session, not to this projection.
    private weak var cards: ComposerShellState?

    private init() {}

    func attach(cards: ComposerShellState) {
        self.cards = cards
    }

    func detachComposer(cards candidate: ComposerShellState) {
        guard cards === candidate else { return }
        cards = nil
    }

    var composerCards: ComposerShellState? { cards }

}

// MARK: - Pages

struct QuietPage: Sendable, Equatable {
    let value: QuietToolPage
    var id: String { value.id }
    var title: String { value.title }
    var summary: String { value.summary }
    /// The rail item the window opens for this page: its own page, or for a door-only page the page where the person sees and sets it.
    var item: SidebarItem {
        switch id {
        case "chat", "make", "simple", "simple_settings_menu": .chat
        case "today": .activity
        case "inbox", "notifications": .inboxPolicy
        case "memories": .memories
        case "desk": .desk
        case "bots": .bots
        case "personality": .personality
        case "providers": .providers
        case "trust", "files", "shell", "web", "browser", "mac", "mail", "calendar", "reminders", "notes", "contacts", "messages", "music": .trust
        case "connectors", "pairing", "agents", "telegram", "slack": .connectors
        case "capabilities", "skills", "tools": .capabilities
        case "diagnostics": .diagnostics
        case "settings": .settings
        default: .ownPage
        }
    }
}

enum QuietPages {
    static let all = QuietToolPage.all.map(QuietPage.init)
    static var ids: [String] { QuietToolPage.ids }
    /// The draw-only page that pictures Simple on Control's Settings tab.
    static let simpleSettings = "simple_settings_menu"
    static let drawOnly: [QuietPage] = [
        QuietPage(value: QuietToolPage(id: "simple", title: "Simple view",
                  summary: "The Simple shell on Chat: my card, the places, the folded Agents and Helpers lists, and the chat.")),
        QuietPage(value: QuietToolPage(id: simpleSettings, title: "Simple view settings",
                  summary: "The Simple shell on Control's Settings tab, where Simple's settings live.")),
    ]
    /// An app page by name or alias, or a page of the agent's own by its id.
    @MainActor static func page(named raw: String) -> QuietPage? {
        let key = AppDoorNames.resolve(raw)
        if key == "inbox" { return QuietPage(value: .inbox) }
        if let page = QuietToolPage.page(named: raw) { return QuietPage(value: page) }
        guard let appModel = ApplicationLifetime.shared.appModel else { return nil }
        return own(appModel, ids: [key]).first
    }

    /// The page the window draws for a rail item, as the door names it (`ShellPageContent.doorPage`); nil for a page of the agent's own,
    /// which the selection names by its id.
    @MainActor static func shown(_ item: SidebarItem) -> QuietPage? {
        ShellPageContent.doorPage(item).flatMap(page(named:))
    }

    /// Only the requested page titles are observed; the catalog supplies claim and inventory availability.
    @MainActor static func own(_ appModel: AppModel, ids: Set<String>) -> [QuietPage] {
        guard let catalog = appModel.face.slot(PageFaceKey.catalog).value(as: PartFaceCatalog.self) else { return [] }
        return descriptions(catalog, ids: ids) { appModel.face.slot(.page($0)).value(as: PartFaceSnapshot.self) }
    }

    private static func descriptions(_ catalog: PartFaceCatalog, ids: Set<String>,
                                     snapshot: (String) -> PartFaceSnapshot?) -> [QuietPage] {
        catalog.claims.filter { ids.contains($0.key) }.sorted { $0.key < $1.key }.map { id, claim in
            let title = snapshot(id)?.face?.title.flatMap { $0.isEmpty ? nil : $0 } ?? id
            let summary: String
            if let failure = catalog.failure { summary = failure.message } else {
                switch claim {
                case .success(let part): summary = "A page of the agent's own, drawn by its part \(part) from that part's notebook."
                case .failure(let failure): summary = failure.message
                }
            }
            return QuietPage(value: QuietToolPage(id: id, title: title, summary: summary))
        }
    }
}
