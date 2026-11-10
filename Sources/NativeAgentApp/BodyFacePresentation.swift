import AppToolRuntime
import Dispatcher
import EngineRuntime
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `BodyFacePresentation.swift` | Connection-bound tool presentations and applied-frame page screenshots |

@MainActor
struct BodyFacePresentation: QuietToolPresentationPort {
    private static var attachedConnection: UUID?
    private static var reportedScene: SceneReport?
    let connection: UUID
    let model: AppModel

    static func connect(_ connection: UUID) { attachedConnection = connection; reportedScene = nil }
    static func disconnect(_ connection: UUID?) {
        if attachedConnection == connection { attachedConnection = nil; reportedScene = nil }
    }
    static func require(_ connection: UUID, model: AppModel) throws -> Self {
        guard attachedConnection == connection else { throw FaceWireError.disconnected }
        return Self(connection: connection, model: model)
    }
    static func current(model: AppModel) throws -> Self {
        guard let connection = attachedConnection else { throw FaceWireError.disconnected }
        return try require(connection, model: model)
    }
    static func report(_ scene: SceneReport) throws {
        guard attachedConnection == scene.connection else { throw FaceWireError.disconnected }
        reportedScene = scene.mounted ? scene : nil
    }
    var scene: SceneReport? { Self.attachedConnection == connection ? Self.reportedScene : nil }
    var isConnected: Bool { Self.attachedConnection == connection }
    var pages: [QuietToolPage] { get async throws { try await AppQuietToolPresentation().pages } }
    var currentPage: QuietToolPage? { scene?.destination.flatMap { QuietPages.page(named: $0.page)?.value } }
    var visiblePageInput: [String: JSONValue]? {
        guard let target = scene?.destination else { return nil }
        var fields: [String: JSONValue] = ["page": .string(target.page)]
        if let item = target.item { fields["item"] = .string(item) }
        return fields
    }
    func page(named raw: String) async -> QuietToolPage? { await QuietPages.ownerPage(named: raw, appModel: model)?.value }
    func call(_ request: FaceCall) async throws -> FaceReply {
        guard Self.attachedConnection == connection else { throw FaceWireError.disconnected }
        return try await model.engine.faceActs.call(request, renderer: connection)
    }
    func present(_ request: FaceCall) async throws {
        try BodyInboxCardActionEffects.requirePresentation(try await call(request))
    }
    func act(_ request: FaceAct) async throws -> FaceActReply {
        guard Self.attachedConnection == connection else { throw FaceWireError.disconnected }
        return try await model.engine.faceActs.handle(request, renderer: connection)
    }
    func contextReceiptRead(input: [String: JSONValue]) async -> JSONValue {
        if input["session_id"]?.scalarText?.isEmpty == false || input["__session_id"]?.scalarText?.isEmpty == false {
            return await AppQuietToolPresentation().contextReceiptRead(input: input)
        }
        guard let session = scene?.composerSession else {
            return AppToolExecutor.failure("composer_unmounted", "Open the conversation's composer before reading its receipt.")
        }
        var fields = input
        if fields["session_id"] == nil { fields["session_id"] = .string(session) }
        return await AppQuietToolPresentation().contextReceiptRead(input: fields)
    }
    func agentViewRead(input: [String: JSONValue]) async -> JSONValue {
        if input["session_id"]?.scalarText?.isEmpty == false { return await AppQuietToolPresentation().agentViewRead(input: input) }
        guard let session = scene?.selectedSession else {
            return AppToolExecutor.failure("conversation_unavailable", "Choose a conversation before reading its Agent view.")
        }
        var fields = input
        if fields["session_id"] == nil { fields["session_id"] = .string(session) }
        return await AppQuietToolPresentation().agentViewRead(input: fields)
    }

    func composerPresentation(verb: String, value: String, choice: String, callerTurn: String?) async -> QuietComposerOutcome? {
        let request: FaceCall
        switch verb {
        case "open_card": request = .openComposerCard(name: value)
        case "close_card": request = .closeComposerCard
        case "set_page":
            let key = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let page: String
            let item: String?
            if let home = QuietComposerCommands.tabs[key], let door = ShellPageContent.doorPage(home.page) {
                page = door; item = home.tab
            } else { page = value; item = choice.isEmpty ? nil : choice }
            request = .navigate(.init(destination: .init(page: page, item: item, session: nil, message: nil), policy: .quiet))
        case "show_pane": request = .showWorkPane(tab: value, reference: choice.isEmpty ? nil : choice, turn: callerTurn)
        case "hide_pane": request = .hideWorkPane
        default: return nil
        }
        do {
            let reply = try await call(request)
            switch reply {
            case .workPane: break
            default: try BodyInboxCardActionEffects.requirePresentation(reply)
            }
            return .done(verb, "The window confirmed the presentation.")
        } catch { return .refuse(verb, "presentation_failed", error.localizedDescription, effects: .unknown) }
    }

    func pageScreenshot(input: [String: JSONValue], imageSink: LocalToolImage.Sink?) async -> JSONValue {
        let requested = input["page"]?.scalarText ?? ""
        let resolved = AppDoorNames.resolve(requested)
        let target: QuietToolPage?
        if resolved == "current" { target = currentPage }
        else { target = await page(named: resolved) ?? QuietPages.drawOnly.first { $0.id == resolved }?.value }
        guard let target else { return AppToolExecutor.failure("page_unavailable", "Name an available page to render.") }
        let tabKey = (input["tab"]?.scalarText ?? "").lowercased()
        var tab: String?
        if !tabKey.isEmpty {
            let item = QuietPage(value: target).item
            let rail = SidebarItem.shellHome(for: item)?.parent ?? item
            guard let home = QuietComposerCommands.tabs[tabKey], home.page == rail else {
                return AppToolExecutor.failure("unknown_tab", "Choose a tab belonging to this page.")
            }
            tab = home.tab
        }
        var height = 860.0
        if let value = input["height"] {
            guard let supplied = value.scalarText.flatMap(Double.init), supplied.isFinite else {
                return AppToolExecutor.failure("invalid_height", "Screenshot height must be a finite number.")
            }
            height = min(max(supplied, 400), 2400)
        }
        let reader = UUID()
        let transcripts = BodyFaceTranscripts(engine: model.engine)
        let result: JSONValue
        do {
            var workPane: WorkPaneSnapshot?
            if let failure = await QuietPages.prepareOwnPage(target.id, appModel: model) { throw failure }
            let item = QuietPage(value: target).item
            let rail = SidebarItem.shellHome(for: item)?.parent ?? item
            let layout = model.engine.layout.availability
            _ = try layout.get()
            if tab == nil {
                switch rail {
                case .memories: tab = "memories"
                case .personality: tab = "personality"
                default:
                    tab = SidebarItem.shellHome(for: item)?.tab
                        ?? ShellRailTab.all(layout).first(where: { $0.page == rail })?.tabs.first?.key
                }
            }
            if rail == .diagnostics, let tab,
               ShellRailTab.all(layout).first(where: { $0.page == rail })?.tabs.contains(where: { $0.key == tab }) != true {
                throw PartCallError(code: "capture_tab_unavailable", message: "This Diagnostics tab is absent from the current layout.")
            }
            let nativePage = ShellPageContent.doorPage(item)
            if rail == .chat {
                _ = try await model.engine.transcripts.readSessionIndex()
                await model.engine.transcripts.refreshNavigationIdentity()
                await model.engine.transcripts.deliverSessionFaces()
                guard let session = scene?.selectedSession, !session.isEmpty else {
                    throw PartCallError(code: "conversation_unavailable", message: "Choose a conversation before rendering Chat.")
                }
                switch await model.engine.providers.refreshSettings(refreshCatalog: false, cause: UserFacingError.cause) {
                case .loaded: break
                case .failed(let issue): throw PartCallError(code: "providers_unavailable", message: issue)
                }
                let choice = await model.engine.providers.refreshSession(session)
                if choice.choice == nil, let issue = choice.error { throw PartCallError(code: "chat_choice_unavailable", message: issue) }
                try await model.engine.providers.deliverFaces()
                _ = try await transcripts.handle(.openTranscriptReader(.init(session: session, presentation: "chat",
                    geometry: .init(reader: reader, width: 1280, scale: 1, viewportHeight: height), openingParagraphCount: 120)))
            } else {
                let receipt = await model.refreshForSidebarItem(item)
                try Task.checkCancellation()
                guard receipt.failedEndpoints.isEmpty else {
                    throw PartCallError(code: "page_refresh_failed",
                        message: "Couldn't refresh " + item.rawValue + ": " + receipt.failedEndpoints.joined(separator: ", ") + ".")
                }
                let page = nativePage ?? target.id
                guard let reading = await model.engine.pages.refresh(page: page) else {
                    throw PartCallError(code: "page_unavailable", message: "The page has no registered body owner.")
                }
                if let failure = reading.error { throw failure }
                await model.engine.pages.flush()
            }
            let preparationPage = QuietPages.drawOnly.contains(where: { $0.id == target.id }) ? target.id : nativePage ?? target.id
            try await model.engine.faceActs.preparePageCapture(page: preparationPage, tab: tab)
            if rail == .chat, !QuietPages.drawOnly.contains(where: { $0.id == target.id }) {
                _ = try await BodySettingsPreferences.refreshPreferences(engine: model.engine,
                    keys: [WorkPaneState.widthKey, WorkPaneState.sidebarsHiddenKey])
                try await model.engine.settingsFeed.deliverFaces()
                _ = try await model.engine.face.flush(sink: connection)
                guard case .workPane(let pane) = try await call(.readWorkPane) else {
                    throw PartCallError(code: "capture_pane_unconfirmed", message: "The window did not supply its Work pane selection.")
                }
                workPane = pane
                try await model.engine.faceActs.prepareWorkPaneCapture(pane)
            }
            try await model.engine.settingsFeed.deliverFaces()
            let barrier = try await model.engine.face.flush(sink: connection)
            let request = PageRenderRequest(page: target.id, tab: tab, width: 1280, height: height,
                epoch: connection, barrier: barrier, reader: reader, workPane: workPane)
            let reply = try await call(.renderPage(request))
            guard case .rendered(let image) = reply else {
                try BodyInboxCardActionEffects.requirePresentation(reply)
                throw PartCallError(code: "render_reply_invalid", message: "The window returned no page image.")
            }
            if let failure = image.failure { throw failure }
            guard image.epoch == connection, image.appliedBarrier == barrier, let png = image.png,
                  image.pixelWidth > 0, image.pixelHeight > 0 else { throw FaceWireError.invalidFeedOrder }
            result = await Self.save(target, tab: tabKey, root: model.engine.dataRoot, image: image, png: png, sink: imageSink)
        } catch { result = AppToolExecutor.failure("render_failed", error.localizedDescription) }
        await settle { await transcripts.close() }
        return result
    }
    @concurrent private static func save(_ page: QuietToolPage, tab: String, root: URL, image: PageRenderResult, png: Data,
                                        sink: LocalToolImage.Sink?) async -> JSONValue {
        AppToolExecutor.pageScreenshotResult(page: page, tabKey: tab, dataRoot: root,
            rendered: (png, image.pixelWidth, image.pixelHeight), imageSink: sink)
    }
}

extension BodyFacePresentation {
    func upkeep(verb: String) async -> (ok: Bool, detail: String, fields: [String: JSONValue])? {
        do {
            switch verb {
            case "trust_workbench":
                let policy = try await model.engine.trust.load()
                guard policy.macControlPolicy != nil else { return (false, "Mac control policy is unavailable.", [:]) }
                try await present(.showMacControlWorkbench)
            case "settings_data_limits": try await present(.openBundledReference(name: "data-bounds"))
            case "settings_update":
                switch try await UpdateController.shared.request(.check, presentation: self) {
                case .acknowledged: break
                case .failed(let issue), .refused(let issue): throw issue
                default: throw FaceWireError.invalidFeedOrder
                }
            case "settings_copy_build_identity":
                try await present(.copyText(AppQuietSettingsHost.settingsBuildIdentity))
            case "trust_exclude_app":
                let reply = try await call(.chooseActivityExclusion(operation: UUID()))
                if case .cancelled = reply { return (true, "Exclusion cancelled; nothing changed.", ["changed": .bool(false)]) }
                guard case .exclusion(let exclusion) = reply, let exclusion, exclusion.confirmed else {
                    try BodyInboxCardActionEffects.requirePresentation(reply)
                    throw PartCallError(code: "exclusion_unconfirmed", message: "The window did not confirm an activity exclusion.")
                }
                let controller = model.engine.activityWatch
                await controller.addExclusion(bundleID: exclusion.bundleID)
                guard try await controller.checkedPolicy().excludedBundleIDs.contains(exclusion.bundleID),
                      let count = controller.lastPurgedRowCount else {
                    throw PartCallError(code: "exclusion_unconfirmed", message: "Exclusion and deletion could not both be confirmed.")
                }
                return (true, "Excluded \(exclusion.bundleID); deleted \(count) recorded spans.", ["changed": .bool(true)])
            default: return nil
            }
            return (true, "The window confirmed the presentation.", [:])
        } catch { return (false, error.localizedDescription, ["effects": .string("unknown")]) }
    }
}
