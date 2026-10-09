import AppToolRuntime
import Dispatcher
import Foundation
import NativeAgentCore
import PersistenceCore

@MainActor struct AppQuietToolPresentation: QuietToolPresentationPort {
    private static func pageValue(_ page: QuietPage) -> QuietToolPage {
        QuietToolPage(id: page.id, title: page.title, summary: page.summary)
    }
    var pages: [QuietToolPage] { QuietPages.all.map(Self.pageValue) }
    var currentPage: QuietToolPage? { NativeAgentAppCoordinator.shared.currentPage.map(Self.pageValue) }
    func page(named raw: String) -> QuietToolPage? { QuietPages.page(named: raw).map(Self.pageValue) }
    /// `app {page: "context", item: session_id}`: the composer's context
    /// receipt for a conversation, read from the turn traces by the same code
    /// the popover uses, line for line — the popover need not be open.
    /// Defaults to the conversation on screen.
    @MainActor
    func contextReceiptRead(input: [String: JSONValue]) async -> JSONValue {
        guard let appModel = QuietSelfAdmin.shared.appModel else { return AppToolExecutor.unattachedFailure() }
        let sessionId = [Self.text(input["session_id"]), Self.text(input["__session_id"])]
            .first { !$0.isEmpty } ?? appModel.activeChatSessionId
        let state = await ComposerContextReceiptReader.load(
            sessionId: sessionId, selectedModel: appModel.chatModel
        )
        let lines = ComposerContextReceiptPresentation.lines(state)
        return AppToolExecutor.pageReadResult(page: "context", fields: [
            "status": .string("ok"),
            "title": .string("Context"),
            "session_id": .string(sessionId),
            "content": .array(lines.map { .string($0.label) }),
            "rows": .array(lines.map { .object(["id": .string($0.id), "label": .string($0.label)]) }),
        ])
    }

    /// `app {page: "agent_view", item: room}`: one Agent-view tab's
    /// text, from the pane's own render (read-only: nothing marked seen or
    /// written, no tool run); no room lists the tabs. Defaults to the
    /// conversation on screen, as the pane does.
    @MainActor
    func agentViewRead(input: [String: JSONValue]) async -> JSONValue {
        guard let appModel = QuietSelfAdmin.shared.appModel else { return AppToolExecutor.unattachedFailure() }
        let tabs = JSONValue.array(AgentScreenView.tabs.map { .string($0) })
        let room = Self.text(input["room"]).lowercased()
        guard !room.isEmpty else {
            return AppToolExecutor.pageReadResult(page: "agent_view", fields: ["status": .string("ok"), "title": .string("Agent view"), "tabs": tabs])
        }
        guard AgentScreenView.tabs.contains(room) else {
            return AppToolExecutor.failure("unknown_room", "The Agent view has no tab called that.", extra: ["requested": .string(room), "tabs": tabs])
        }
        let named = Self.text(input["session_id"])
        let scope = named.isEmpty ? appModel.activeChatSessionId : named
        let root = appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        return AppToolExecutor.pageReadResult(page: "agent_view", fields: [
            "status": .string("ok"), "title": .string("Agent view"), "room": .string(room), "session_id": .string(scope),
            "content": .string(await AgentScreenView.paneText(room, root: root, scope: scope)),
        ])
    }

    // MARK: - page.screenshot

    @MainActor
    func pageScreenshot(input: [String: JSONValue]) async -> JSONValue {
        let requested = Self.text(input["page"])
        guard let page = QuietPages.page(named: requested)
                ?? QuietPages.drawOnly.first(where: { $0.id == requested.lowercased() }) else {
            return AppToolExecutor.unknownPageFailure(requested, pages: QuietPages.ids)
        }
        // A tab by the key page.show takes (`QuietComposerVerbs.tabs`), on
        // this page's own rail page. Without one the page's default tab draws.
        let tabKey = Self.text(input["tab"]).lowercased()
        let railPage = SidebarItem.shellHome(for: page.item)?.parent ?? page.item
        var tab: String?
        if !tabKey.isEmpty {
            guard let home = QuietComposerVerbs.tabs[tabKey], home.page == railPage else {
                let keys = QuietComposerVerbs.tabs.filter { $0.value.page == railPage }.keys.sorted()
                return AppToolExecutor.failure("unknown_tab", "This page has no tab called that.",
                                               extra: ["requested": .string(tabKey), "tabs": .array(keys.map { .string($0) })])
            }
            tab = home.tab
        }
        guard let appModel = QuietSelfAdmin.shared.appModel else { return AppToolExecutor.unattachedFailure() }
        var size = QuietSelfAdminRender.defaultSize
        switch input["height"] {
        case .int(let value)?: size.height = CGFloat(value)
        case .double(let value)?: size.height = CGFloat(value)
        case .string(let value)?: size.height = Double(value).map { CGFloat($0) } ?? size.height
        default: break
        }
        size.height = min(max(size.height, 400), 2400)
        guard let rendered = await QuietSelfAdminRender.pageImagePNG(for: page, tab: tab, appModel: appModel, size: size) else {
            return AppToolExecutor.failure("render_failed", "The page could not be drawn offscreen.")
        }
        // Every picture is also a file, so whoever asked can open the PNG.
        let folder = (appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())
            .appendingPathComponent("diagnostics/page_shots", isDirectory: true)
        let stamp = ISO8601DateFormatter.string(
            from: Date(), timeZone: .current, formatOptions: [.withYear, .withMonth, .withDay, .withTime])
        let file = folder.appendingPathComponent("\(page.id)\(tabKey.isEmpty ? "" : "-" + tabKey)-\(stamp)-\(UUID().uuidString.lowercased()).png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try rendered.data.write(to: file, options: .atomic)
        } catch {
            return AppToolExecutor.failure("write_failed", "The picture could not be saved: \(error.localizedDescription)")
        }
        do {
            // The current file stays protected until delivery. Inline delivery
            // owns the encoded bytes, so later trims cannot invalidate pixels
            // already handed to an active model continuation.
            try Self.prunePageShots(in: folder, preserving: file)
        } catch {
            return AppToolExecutor.failure("retention_failed", "The picture was saved, but diagnostic retention could not finish: \(error.localizedDescription)",
                                           extra: ["path": .string(file.path)])
        }
        // A text-only call (the Claude bridge) has no turn to show pixels in:
        // the path comes back instead.
        if LocalToolImage.sink == nil {
            return .object([
                "status": .string("ok"), "page": .string(page.id), "title": .string(page.title),
                "path": .string(file.path),
                "width": .int(Int64(rendered.width)), "height": .int(Int64(rendered.height)),
                "note": .string("An offscreen drawing saved as a PNG; this call has no turn to show pixels in."),
            ])
        }
        guard case .object(var delivery) = LocalToolImage.deliverPNG(
            rendered.data, name: "\(page.id).png",
            width: rendered.width, height: rendered.height
        ) else {
            return AppToolExecutor.failure("image_delivery_failed", "The picture could not be handed to the model.")
        }
        delivery["page"] = .string(page.id)
        delivery["title"] = .string(page.title)
        delivery["path"] = .string(file.path)
        delivery["note"] = .string(
            "An offscreen drawing of this page, not a capture of the screen. The app was not brought "
            + "forward and nothing on screen changed.")
        return .object(delivery)
    }

    private static func text(_ value: JSONValue?) -> String {
        guard case .string(let raw)? = value else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replaceable offscreen pictures: seven days, 64 files, 64 MiB. The
    /// picture being returned is always kept, even if it alone exceeds a bound.
    private static func prunePageShots(in folder: URL, preserving current: URL, now: Date = Date()) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "png" }
        var captures: [(url: URL, bytes: Int, modified: Date)] = []
        for file in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let bytes = values.fileSize, let modified = values.contentModificationDate else { continue }
            captures.append((file, bytes, modified))
        }
        captures.sort {
            $0.modified == $1.modified ? $0.url.lastPathComponent < $1.url.lastPathComponent : $0.modified < $1.modified
        }
        var count = captures.count
        var bytes = captures.reduce(0) { $0 + $1.bytes }
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        for capture in captures where capture.url != current {
            guard capture.modified < cutoff || count > 64 || bytes > 64 * 1024 * 1024 else { continue }
            try FileManager.default.removeItem(at: capture.url)
            count -= 1
            bytes -= capture.bytes
        }
    }
}
