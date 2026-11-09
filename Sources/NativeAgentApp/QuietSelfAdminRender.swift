import Connectors
import BackgroundWork
import ApprovalTransactions
import AppToolRuntime
import AgentWorkspace
import AuthoredCapabilities
import ChatToolRuntime
import ChatToolParsing
import AppKit
import ChatTurnRuntime
import Foundation
import Dispatcher
import EngineRuntime
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Desk
// Read the page owners directly so quiet projections cannot drift into another store.
import ProviderRouting
import StandingBots
import SwiftUI
import MacIntegration
import MemoryV2
import ToolRegistry
import ToolExecution
import TrustCenter
import TrustPersistence
// Blueprint: | `QuietSelfAdminRender.swift` | Body page-owner text reads, card facts, catalog and renderer-bound screenshots |

@MainActor
enum QuietSelfAdminRender {
    /// Read through the page's owner.
    static func pageRead(for page: QuietPage, appModel: AppModel, turn: Turn? = nil, face: BodyFacePresentation? = nil) async -> [JSONValue] {
        var content = await pageProjection(for: page, appModel: appModel, turn: turn, face: face)
        if let failure = appModel.engine.layout.availability.failure {
            content.insert(layoutIssue(failure), at: 0)
        }
        return content
    }

    private static func pageProjection(for page: QuietPage, appModel: AppModel, turn: Turn?, face: BodyFacePresentation?) async -> [JSONValue] {
        if page.id == "chat" { return await chatProjection(appModel: appModel, turn: turn, face: face) }
        guard page.item == .ownPage || QuietPages.shown(page.item)?.id == page.id else {
            // An app whose access the person sets on Trust reads Trust's rows for it, as Trust draws them now.
            let access: DoorPageAccess
            if page.item == .trust { access = .trust(await appModel.engine.pages.refresh(page: "trust")) } else { access = .notOnTrust }
            return AppToolExecutor.doorPageRead(page.value, access: access, turn: turn)
        }
        // A page of the agent's own reads itself through engine.pages; the others load their shared data first.
        if page.item != .chat, page.item != .activity, page.item != .memories, page.item != .bots, page.item != .ownPage {
            _ = await appModel.refreshForSidebarItem(page.item)
        }
        guard let snapshot = await appModel.engine.pages.refresh(page: page.id) else {
            if page.id == "today" {
                return [.object(["heading": .string(page.title), "lines": .array([.string("Reading Today…")])])]
            }
            return [issue(page.title, reason: "page_unavailable", detail: "\(page.id) has not published its required face.",
                instruction: "Read this page again after its owner publishes; preserve the owner's failure if it remains unavailable.",
                next: ["page": .string(page.id)])]
        }
        return snapshot.text(title: page.title, door: true, page: page.id).components(separatedBy: "\n\n").filter { !$0.isEmpty }.map { block in
            var lines = block.components(separatedBy: "\n")
            var heading = page.title
            if let first = lines.first, first == snapshot.face?.title || first.hasSuffix(":") {
                heading = first.hasSuffix(":") ? String(first.dropLast()) : first
                lines.removeFirst()
            }
            // The face's text already bounds each row's words and keeps its reference (id, link, calls) whole; it is not cut again.
            return .object(["heading": .string(heading), "lines": .array(lines.map(JSONValue.string))])
        }
    }

    private static func layoutIssue(_ failure: SurfaceLayoutFailure) -> JSONValue {
        issue("Layout unavailable", reason: "invalid_file", detail: failure.localizedDescription, instruction: failure.instruction)
    }

    // MARK: Sections

    private static func bounded(_ raw: String) -> String {
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > 200 else { return collapsed }
        return String(collapsed.prefix(199)) + "\u{2026}"
    }

    private static func section(_ heading: String, _ lines: [String]) -> JSONValue {
        .object([
            "heading": .string(heading),
            "lines": .array(lines.map { .string(bounded($0)) }),
        ])
    }

    /// Keep failure and recovery structured, outside the section's 200-character summary cap.
    private static func issue(_ heading: String, reason: String, detail: String, instruction: String,
                              next: [String: JSONValue]? = nil, error: (any Error)? = nil) -> JSONValue {
        let remedy = Repair.remedy(owner: heading,
            nextCall: next.map { .object(["tool": .string("app"), "input": .object($0)]) }, tap: nil, instruction: instruction)
        var face: [String: JSONValue] = [
            "heading": .string(heading), "lines": .array([]),
            "status": .string("unavailable"), "reason": .string(reason), "detail": .string(detail),
            "remedy": remedy,
        ]
        if let error, case .object(let evidence) = ChatToolOutcome.failure(error: error, effects: ToolFailureError.Effects.none) {
            face.merge(evidence) { _, owned in owned }
            if evidence["reason"] == .string("dispatch_error") {
                face["reason"] = .string(reason)
                face["failure_code"] = .string(reason)
            }
        }
        return .object(face)
    }

    private static func countLine(_ count: Int, _ one: String, _ many: String) -> String {
        count == 1 ? "1 \(one)" : "\(count) \(many)"
    }

    // MARK: Chat

    /// Include transcript folds and cards that the offscreen accessibility tree cannot expose.
    private static func chatProjection(appModel: AppModel, turn: Turn?, face: BodyFacePresentation?) async -> [JSONValue] {
        let composer: [String: JSONValue]
        let sessionID: String
        let paneRows: [String]
        var workPane: String?
        if let face {
            do {
                composer = try await BodyQuietChatCommands(face: face).composerState(sessionID: "", turn: turn)
                guard case .string(let selected)? = composer["conversation"] else { throw FaceWireError.invalidFeedOrder }
                sessionID = selected
                if case .array(let rows)? = composer["pane_rows"] { paneRows = rows.compactMap(\.scalarText) }
                else { throw FaceWireError.invalidFeedOrder }
                if !sessionID.isEmpty { _ = try await appModel.engine.transcripts.refreshMessages(sessionId: sessionID, cached: true) }
                // The Work pane is the window's: its state is read from the window, as shown.
                guard case .workPane(let pane) = try await face.call(.readWorkPane) else { throw FaceWireError.invalidFeedOrder }
                workPane = pane.isVisible ? "open" + (pane.tab.map { " on \($0)" } ?? "") : "closed"
            } catch {
                return [issue("Chat", reason: "chat_window_unavailable", detail: error.localizedDescription,
                    instruction: "Open this window's conversation and resolve its read error before reading Chat.",
                    next: ["page": .string("chat")], error: error)]
            }
        } else {
            return [issue("Chat", reason: "chat_window_unavailable", detail: "No window is attached.",
                instruction: "Open NativeAgent's window before reading its conversation.",
                next: ["page": .string("chat")], error: FaceWireError.disconnected)]
        }
        guard !sessionID.isEmpty else {
            return [section("Chat", ["No conversation is open."])]
        }
        let messages = appModel.engine.transcripts.displayedTranscript(for: sessionID).messages
        await appModel.engine.transcripts.prepareGroups(for: sessionID)
        let groups = appModel.engine.transcripts.groups(for: sessionID)
        var sections: [JSONValue] = [section("Chat", [
            "Conversation: \(sessionID)",
            countLine(messages.count, "message", "messages") + " loaded.",
        ])]

        func line(_ label: String, _ key: String) -> String? {
            switch composer[key] {
            case .string(let value): return "\(label): \(value)"
            case .int(let value): return "\(label): \(value)"
            case .bool(let value): return "\(label): \(value ? "on" : "off")"
            default: return nil
            }
        }
        sections.append(section("Composer", [
            line("Draft", "draft") ?? "Draft: (empty)",
            line("Model", "model_word") ?? "",
            line("Thinking", "think_word") ?? "",
            line("Trust", "trust_word") ?? "",
            line("Context used", "ring_percent").map { $0 + "%" } ?? "Context used: unknown",
            line("Context measurement", "context_measurement_source") ?? "Context measurement: unknown",
            line("Open composer card", "open_card") ?? "",
            workPane.map { "Work pane: " + $0 } ?? "",
            "The chat.* actions work this row in process.",
        ].filter { !$0.isEmpty } + paneRows))

        var foldLines: [String] = []
        for group in groups where group.isToolGroup {
            foldLines.append(await appModel.engine.transcripts.prepareToolFold(group.messages))
        }
        if !foldLines.isEmpty {
            sections.append(section("Tool folds", foldLines))
        }

        do {
            let read = try await appModel.engine.transcripts.loadTranscript(sessionId: sessionID)
            sections += chatCards(read)
        } catch {
            sections.append(issue("Cards", reason: "chat_cards_unavailable",
                detail: error.localizedDescription,
                instruction: "Resolve the reported conversation read problem without deleting its history, then reload Chat.",
                next: ["page": .string("chat")], error: error))
        }
        return sections
    }

    /// The cards in the open conversation, each with its id, state and what answering it takes.
    private static func chatCards(_ read: TranscriptReadout) -> [JSONValue] {
        var sections: [JSONValue] = []
        let pairs = read.messages.flatMap { message in
            message.inlineCards.map { (rowID: message.id, card: $0.model) }
        }
        guard !pairs.isEmpty else { return sections }
        sections.append(section(
            "Cards",
            [read.cardsHeading
                + " in this conversation. card.answer answers one by its id."]
        ))
        return sections + pairs.map { chatCard($0.card, rowID: $0.rowID) }
    }

    private static func chatCard(_ card: InlineCardModel, rowID: String) -> JSONValue {
        // Unknown, declined and settled cards retain their receipt and interaction identity.
        switch card.state {
        case .superseded:
            // Superseded asks have no remaining decision because a newer identical ask owns it.
            return cardSection(card, [
                "State: " + card.state.rawValue,
                "Asked earlier — a newer copy of this ask took its place.",
                "Interaction id: \(card.id)",
                "On message: \(rowID)",
            ])
        case .unknown, .declined, .settled:
            var receipt: [String] = ["State: \(card.state.rawValue)"]
            if let outcome = card.outcome { receipt.append(outcome) }
            if let meta = card.outcomeMeta { receipt.append(meta) }
            receipt.append("Interaction id: \(card.id)")
            receipt.append("On message: \(rowID)")
            return cardSection(card, receipt)
        case .pending, .running, .failed, .stopped:
            // Failure settles nothing: retain the card’s explanation, field and retry control rather than presenting a receipt.
            break
        }
        var lines: [String] = ["State: \(card.state.rawValue)"]
        if !card.why.isEmpty { lines.append("Why: \(card.why)") }
        if card.state == .running, let note = card.busyNote { lines.append("Working: \(note)") }
        if let restart = card.restartNote { lines.append("Restart: \(restart) Only the person's tap on the card restarts.") }
        lines.append(contentsOf: card.scopeLines)
        if card.state == .failed && !card.canRetry {
            // Never name controls this build cannot draw.
            lines.append("There is no control for this on this build, so it can't be answered here.")
        } else {
            lines.append("Do: \(card.state == .stopped ? "Resume" : card.state == .failed ? "Try again" : card.primaryLabel)")
            lines.append(
                "Or: \(card.secondaryLabel) — "
                    + InlineInteraction.lowercasedLead(
                        card.consequence.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
            )
        }
        if let note = card.persistenceNote { lines.append(note) }
        if let signIn = card.signInLabel { lines.append("Offers: \(signIn)") }
        for field in card.fields {
            lines.append(
                "Takes: \(field.label)\(field.isSecret ? " (secret — the person types it into the card, never into chat)" : "")"
            )
        }
        for choice in card.choices {
            lines.append("Choice \(choice.id): \(choice.title)"
                + (choice.note.map { " — \($0)" } ?? ""))
        }
        if let outcome = card.outcome { lines.append("Outcome: \(outcome)") }
        if let meta = card.outcomeMeta { lines.append(meta) }
        lines.append("Interaction id: \(card.id)")
        lines.append("On message: \(rowID)")
        return cardSection(card, lines)
    }

    private static func cardSection(_ card: InlineCardModel, _ lines: [String]) -> JSONValue {
        var face: [String: JSONValue] = [
            "heading": .string(card.title), "lines": .array(lines.map { .string(bounded($0)) }),
            "status": .string(card.state.rawValue), "card": .string(card.id),
        ]
        if let outcome = card.outcome { face["outcome"] = .string(outcome) }
        if let meta = card.outcomeMeta { face["outcome_meta"] = .string(meta) }
        let unsupportedInstruction = """
            Tell the person: this copy of NativeAgent has no control for card \(card.id) (\(card.title)). Preserve the card; no answer can run \
            here.
            """
        let unsupported = Repair.remedy(owner: "NativeAgent card controls", nextCall: nil, tap: unsupportedInstruction,
            instruction: unsupportedInstruction)
        switch card.state {
        case .stopped:
            face["reason"] = .string(DataRootLife.stoppedReason)
            face["remedy"] = Repair.remedy(owner: card.title, nextCall: nil,
                tap: "Chat → \(card.title) [\(card.id)] → Resume",
                instruction: "The person can use Resume to start this request fresh after the restore.")
        case .unknown:
            face["reason"] = .string("card_unsupported")
            face["detail"] = .string(card.outcome ?? "This build has no control for this card.")
            face["remedy"] = unsupported
        case .failed:
            face["reason"] = .string(card.canRetry ? "card_action_failed" : "card_unsupported")
            face["detail"] = .string(card.outcome ?? card.why)
            face["scope"] = .array(card.scopeLines.map(JSONValue.string))
            face["remedy"] = card.canRetry
                ? Repair.remedy(owner: card.title, nextCall: nil,
                    tap: "Chat → \(card.title) [\(card.id)] → Try again",
                    instruction: "Resolve the reported cause; the owner can then use this card's Try again control.")
                : unsupported
        case .pending, .running, .settled, .declined, .superseded:
            break
        }
        return .object(face)
    }
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
        case "dreams", "knowledge", "cognition", "memory-upkeep": .ownPage
        case _ where AppDoorNames.ownPageRefusal(id) == nil: .ownPage
        default: preconditionFailure("The page has no rail route")
        }
    }
}

enum QuietPages {
    static let all = QuietToolPage.all.map(QuietPage.init)
    static var ids: [String] { QuietToolPage.ids }
    static let drawOnly: [QuietPage] = [
        QuietPage(value: QuietToolPage(id: "simple", title: "Simple view",
                  summary: "The Simple shell: the sidebar with its pinned person row, and the chat.")),
        QuietPage(value: QuietToolPage(id: "simple_settings_menu", title: "Simple view settings menu",
                  summary: "The Simple shell with the person row's settings menu drawn open.")),
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

    /// Agent discovery reads its owner directly, independently of the next display frame.
    @MainActor static func ownerPages(_ appModel: AppModel) async throws -> [QuietPage] {
        let pages = appModel.engine.pages
        guard let catalog = await pages.catalog else {
            throw PartCallError(code: "page_inventory_pending", message: "Waiting on the authored-page inventory; read the pages again after it arrives.")
        }
        if let failure = catalog.failure { throw failure }
        let snapshots = await pages.snapshots
        return descriptions(catalog, ids: Set(catalog.claims.keys)) { snapshots[$0] }
    }

    @MainActor static func ownerPage(named raw: String, appModel: AppModel) async -> QuietPage? {
        let key = AppDoorNames.resolve(raw)
        if key == "inbox" { return QuietPage(value: .inbox) }
        if let page = QuietToolPage.page(named: raw) { return QuietPage(value: page) }
        guard let catalog = await appModel.engine.pages.catalog else { return nil }
        let snapshots = await appModel.engine.pages.snapshots
        return descriptions(catalog, ids: [key]) { snapshots[$0] }.first
    }

    /// Navigation and capture resolve inventory absence at its owner, before deciding whether a page exists.
    @MainActor static func prepareOwnPage(_ name: String, appModel: AppModel) async -> PartCallError? {
        guard AppDoorNames.ownPageRefusal(name) == nil else { return nil }
        let pages = appModel.engine.pages
        if await pages.catalog == nil, case .failure(let failure) = await pages.ownPages() { return failure }
        guard let catalog = await pages.catalog else {
            return .init(code: "page_inventory_pending", message: "Waiting on the authored-page inventory; this page request is unconfirmed.")
        }
        return catalog.failure
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

@MainActor struct AppQuietToolPresentation: QuietToolPresentationPort {
    /// Shipped pages exist independently of their presentation in the layout.
    var pages: [QuietToolPage] {
        get async throws {
            guard let appModel = ApplicationLifetime.shared.appModel else {
                throw ToolFailureError("The app presentation has not attached.", effects: .none, code: "app_unattached")
            }
            return QuietToolPage.all + (try await QuietPages.ownerPages(appModel)).map(\.value)
        }
    }
    var currentPage: QuietToolPage? {
        guard let appModel = ApplicationLifetime.shared.appModel else { return nil }
        return (try? BodyFacePresentation.current(model: appModel))?.currentPage
    }
    var visiblePageInput: [String: JSONValue]? {
        guard let appModel = ApplicationLifetime.shared.appModel else { return nil }
        return (try? BodyFacePresentation.current(model: appModel))?.visiblePageInput
    }
    func page(named raw: String) async -> QuietToolPage? {
        guard let appModel = ApplicationLifetime.shared.appModel else { return nil }
        return await QuietPages.ownerPage(named: raw, appModel: appModel)?.value
    }
    /// Read a conversation's context receipt through the popover owner without requiring it to be open.
    /// With no session, use the conversation on screen.
    @MainActor
    func contextReceiptRead(input: [String: JSONValue]) async -> JSONValue {
        guard let appModel = ApplicationLifetime.shared.appModel else { return AppToolExecutor.unattachedFailure() }
        return await AppToolExecutor.contextReceiptRead(input: input, activeSessionID: appModel.activeChatSessionId) { sessionID in
            let state = await ContextReceipts.read(sessionId: sessionID, selectedModel: appModel.chatModel, dataRoot: appModel.engine.dataRoot)
            return ComposerContextReceiptPresentation.lines(state)
        }
    }

    /// Read Agent-view text without marking seen, writing or running a tool.
    /// With no room, list tabs; with no session, use the conversation on screen.
    @MainActor
    func agentViewRead(input: [String: JSONValue]) async -> JSONValue {
        guard let appModel = ApplicationLifetime.shared.appModel else { return AppToolExecutor.unattachedFailure() }
        let layout = appModel.engine.layout.availability
        let result = await AppToolExecutor.agentViewRead(input: input, rooms: AgentScreenPreview.tabs(layout, profile: SimpleViewMode.agent),
                                                   activeSessionID: appModel.activeChatSessionId) { room, scope in
            await appModel.engine.turns.readAgentScreen(room: room, scope: scope)
        }
        if let failure = layout.failure, case .object(var fields) = result {
            fields["layout_issue"] = SurfaceLayoutStore.failureResult(failure)
            return .object(fields)
        }
        return result
    }

    // MARK: - page.screenshot

    @MainActor
    func pageScreenshot(input: [String: JSONValue], imageSink: LocalToolImage.Sink?) async -> JSONValue {
        guard let appModel = ApplicationLifetime.shared.appModel else { return AppToolExecutor.unattachedFailure() }
        do {
            return await (try BodyFacePresentation.current(model: appModel)).pageScreenshot(input: input, imageSink: imageSink)
        } catch {
            return AppToolExecutor.failure("app_window_unavailable", error.localizedDescription)
        }
    }

    private static func text(_ value: JSONValue?) -> String {
        guard case .string(let raw)? = value else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
