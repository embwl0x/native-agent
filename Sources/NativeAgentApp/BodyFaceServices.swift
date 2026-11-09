import AppKit
import BackgroundLoops
import ChatTurnRuntime
import ChatToolParsing
import Cognition
import Desk
import EngineRuntime
import Foundation
import MemoryV2
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Privacy
import Studio
// Blueprint: | `BodyFaceServices.swift` | Body-owned contact, Desk, graph and resource acts for the separate window |

@MainActor
final class BodyFaceServices {
    let engine: NativeAgentEngine
    private var connection: UUID?
    lazy var transcripts = BodyFaceTranscripts(engine: engine)
    lazy var voice = BodyFaceVoice(engine: engine)

    init(engine: NativeAgentEngine) { self.engine = engine }

    func connect(_ connection: UUID) { self.connection = connection }

    func disconnect(_ connection: UUID?) async {
        guard let connection, self.connection == connection else { return }
        self.connection = nil
        await transcripts.close()
        await voice.close()
        await Self.removeProtection(connection)
    }

    func handle(_ act: FaceAct) async throws -> FaceActReply? {
        if let reply = try await transcripts.handle(act) { return reply }
        if let reply = try await voice.handle(act) { return reply }
        switch act {
        case .addDeskNote(let handle, let text):
            let action = DeskQuickAction.note(handle: handle, text: text)
            let result = try await DeskToolDispatchRouter(dataRoot: engine.dataRoot).run(tool: action.tool, input: action.input)
            try Self.requireSuccess(result, action: "desk_note")
            _ = await engine.desk.refreshPage()
            return Self.committed(PartFace.Value(result), identities: [handle])
        case .deskCommand(let request):
            let result = try await desk(request)
            if request.command == "validate" { return .result(result) }
            return Self.committed(result, identities: request.handle.map { [$0] } ?? [])
        case .sendContactMessage(let request):
            guard let session = request.session, !session.isEmpty else {
                throw Self.failure("contact_session_required", "Open a conversation before sending this message.")
            }
            let sessions = try await engine.transcripts.readSessionIndex()
            guard sessions.contains(where: { $0.id == session }) else {
                throw Self.failure("contact_session_missing", "The originating conversation is absent from the checked index. Nothing was sent.")
            }
            let turn = TurnRequest(message: request.text, sessionID: session, surface: "native_actions",
                envelope: .personOnMac("mac_ui:contact.send")).turn()
            if let cause = await engine.sendContactMessage(agent: request.contact, text: request.text, session: session,
                root: engine.dataRoot, turn: turn) {
                throw Self.failure("contact_send_unconfirmed", cause, effects: .unknown)
            }
            return .accepted(session: session, turn: nil, operation: nil)
        case .stopContactMessage(let contact, let record):
            guard let flight = engine.contactThreads.flight(for: contact), flight.recordID == record else {
                throw Self.failure("contact_flight_changed", "That send is no longer the current contact operation. Read the thread before stopping it.")
            }
            if let cause = await engine.stopContactMessage(agent: flight.agent, record: record, session: flight.scope, root: engine.dataRoot) {
                throw Self.failure("contact_stop_unconfirmed", cause, effects: .unknown)
            }
            return Self.committed(.string("Stop recorded."), identities: [contact, record])
        case .withdrawContactMessage(let item, let record):
            let saved = try await engine.withdrawContactMessage(item, record: record, root: engine.dataRoot)
            return Self.committed(.string("Held message withdrawn."), identities: [saved.id, item])
        case .resendContactMessage(let contact, let item, let session):
            return try await resend(contact: contact, item: item, session: session)
        case .exportMake(let request):
            let projectPath: String?
            if case .project(let session) = request.destination {
                let sessions = try await engine.transcripts.readSessionIndex()
                guard let found = sessions.first(where: { $0.id == session }) else {
                    throw Self.failure("make_export_session_missing", "The originating conversation is absent from the checked index. Nothing was exported.")
                }
                projectPath = found.worktreePath
            } else { projectPath = nil }
            return try await Self.exportMake(request, projectPath: projectPath, root: engine.dataRoot)
        case .reportProtectedWindows(let report):
            guard report.connection == connection else { throw FaceWireError.invalidFeedOrder }
            await Self.protectedWindows(report)
            return .acknowledged
        case .reportOverlayWindow(let number):
            guard let connection else { throw FaceWireError.disconnected }
            await Self.overlay(number, connection: connection)
            return .acknowledged
        case .reportRendererDiagnostic(let diagnostic):
            ModuleLog.app("[face:%@] %@", diagnostic.kind, diagnostic.message)
            return .acknowledged
        case .quitBody:
            AppDelegate.terminateFromRunLoop()
            return .acknowledged
        default: return nil
        }
    }

    private func resend(contact: String, item: String, session: String) async throws -> FaceActReply {
        guard let flight = engine.contactThreads.flight(for: contact), flight.scope == session,
              let queued = flight.queued.first(where: { $0.id == item }) else {
            throw Self.failure("held_contact_message_missing", "The held message is absent from the current contact operation. Nothing was sent.")
        }
        guard case .notSent = queued.state else {
            throw Self.failure("contact_message_not_held", "This message is not waiting for an explicit resend. Read its current state.")
        }
        let turn = TurnRequest(message: queued.text, sessionID: session, surface: "native_actions",
            envelope: .personOnMac("mac_ui:contact.send")).turn()
        if let cause = await engine.sendContactMessage(agent: contact, text: queued.text, session: session, root: engine.dataRoot,
            conversation: contact.hasPrefix("bot:") ? nil : flight.recordID, turn: turn) {
            throw Self.failure("contact_resend_unconfirmed", cause, effects: .unknown)
        }
        do { try await engine.withdrawContactMessage(item, record: flight.recordID, root: engine.dataRoot) }
        catch {
            throw WireFailure(code: "contact_replacement_withdrawal_failed", message: "The replacement was accepted; the held copy could not be withdrawn.",
                cause: error.localizedDescription, effects: .known)
        }
        return Self.committed(.string("Replacement accepted; held copy withdrawn."), identities: [contact, item])
    }

    private func desk(_ request: DeskCommandRequest) async throws -> PartFace.Value {
        guard let handle = request.handle else { throw Self.failure("desk_item_required", "Choose a Desk item for this command.") }
        switch request.command {
        case "validate":
            guard request.arguments.isEmpty else { throw Self.failure("desk_command_invalid", "Reading a Desk item takes only its handle.") }
            guard try await engine.desk.store.liveState().items.contains(where: { $0.handle == handle }) else {
                throw Self.failure("desk_item_missing", "No Desk item has this handle.")
            }
            return .string("The Desk item is present.")
        case "make_again":
            guard case .string(let version)? = request.arguments["version"], request.arguments.count == 1 else {
                throw Self.failure("make_version_required", "Choose the image version to make again.")
            }
            let prompt = try await Self.imagePrompt(handle, version: version, root: engine.dataRoot)
            let value = try await DeskToolDispatchRouter(dataRoot: engine.dataRoot).run(tool: "image_generate",
                input: ["prompt": .string(prompt), "__make_ref": .string(handle)])
            try Self.requireSuccess(value, action: "make_again")
            return .string("Image made.")
        case "close", "defer", "note": return try await paletteCommand(request, handle: handle)
        case "select":
            engine.desk.faceItem = handle
            _ = await engine.desk.refreshPage()
            return .string("Desk item selected.")
        case "open":
            if let opening = try await engine.deskOpening(item: handle) {
                switch opening {
                case .show(let item): engine.desk.faceItem = item
                case .request(let presentation):
                    let request: DeskPresentationRequest
                    switch presentation {
                    case .findItem: request = .findItem
                    case .newTask: request = .newTask
                    case .research: request = .research
                    case .note(let item): request = .note(handle: item)
                    case .reply(let draft):
                        try BodyInboxCardActionEffects.requireDraft(try await engine.faceActs.call(.prepareChatDraft(text: draft)))
                        return .string("Desk reply draft opened.")
                    case .copy(let text): request = .copy(text: text)
                    }
                    let reply = try await engine.faceActs.call(.desk(request))
                    switch reply {
                    case .acknowledged: break
                    case .failed(let failure), .refused(let failure): throw failure
                    default: throw FaceWireError.invalidFeedOrder
                    }
                }
            } else { engine.desk.faceItem = handle }
            _ = await engine.desk.refreshPage()
            return .string("Desk item opened.")
        default:
            throw Self.failure("desk_command_owner_unmounted", "This Desk command has no mounted body owner.")
        }
    }

    private func paletteCommand(_ request: DeskCommandRequest, handle: String) async throws -> PartFace.Value {
        guard let verb = DeskPaletteQuery.Verb(rawValue: request.command) else {
            throw Self.failure("desk_command_unknown", "This Desk command is not recognized.")
        }
        let page = await engine.desk.refreshPage()
        if let issue = page.deskUnavailable { throw Self.failure("desk_unavailable", issue) }
        let resolution = DeskPaletteCommandApplication.resolve(verb: verb, handle: handle, activeItems: DeskPageContent.active(page.boardItems))
        switch resolution {
        case .refused(let cause): throw Self.failure("desk_command_refused", cause)
        case .dispatch(let action):
            guard request.arguments.count == 1, let expected = request.arguments["expected_updated_at"],
                  expected == action.input["expected_updated_at"].map({ PartFace.Value($0) }) else {
                throw Self.failure("desk_item_changed", "That item changed after the palette showed it. Nothing was closed; find it again.")
            }
            let result = try await DeskToolDispatchRouter(dataRoot: engine.dataRoot).run(tool: action.tool, input: action.input)
            try Self.requireSuccess(result, action: "desk_close")
            _ = await engine.desk.refreshPage()
            return .string("Desk item closed.")
        case .beginDefer, .beginNote:
            guard request.arguments.isEmpty else { throw Self.failure("desk_command_invalid", "This editor command takes only its Desk item.") }
            engine.desk.faceItem = handle
            _ = await engine.desk.refreshPage()
            do {
                let reply: FaceReply
                if verb == .note { reply = try await engine.faceActs.call(.desk(.note(handle: handle))) }
                else { reply = try await engine.faceActs.call(.navigate(.init(
                    destination: .init(page: "desk", item: nil, session: nil, message: nil), policy: .foreground))) }
                switch reply {
                case .acknowledged where verb == .note: return .string("Opened the note editor.")
                case .navigation(let receipt) where verb == .deferItem && receipt.disposition == .mounted:
                    return .string("Opened this item's park choices on Desk.")
                case .failed(let failure), .refused(let failure): throw failure
                default: throw Self.failure("desk_presentation_unconfirmed", "The Desk editor did not confirm its presentation.")
                }
            } catch {
                throw WireFailure(code: "desk_editor_unavailable", message: "The item was selected, but its editor could not be opened.",
                    cause: error.localizedDescription, effects: .unknown)
            }
        }
    }

    nonisolated private static func requireSuccess(_ value: JSONValue, action: String) throws {
        let result = ToolResult(value)
        guard result.outcome == .succeeded else {
            let effects: FaceEffects = switch result.effects {
            case .none?: .none
            case .occurred?, .partial?: .known
            case .unknown?, nil: .unknown
            }
            throw WireFailure(code: action + "_" + result.outcome.rawValue, message: "The action reported: " + result.outcome.receipt.label,
                cause: try NativeAppSecretRedactor.redactArguments(value).serialize(pretty: true), effects: effects)
        }
    }

    @concurrent private static func imagePrompt(_ reference: String, version: String, root: URL) async throws -> String {
        let studio = MakeStudio(dataRoot: root)
        guard MakeStudio.isRef(reference), let meta = try studio.readMeta(reference),
              let selected = meta.versions.first(where: { String($0.n) == version }),
              MakeStudio.imageTypes.contains(studio.url(reference, selected).pathExtension.lowercased()), let prompt = selected.prompt else {
            throw failure("make_image_prompt_missing", "This image version has no saved prompt. Nothing was generated.")
        }
        return prompt
    }

    @concurrent private static func exportMake(_ request: MakeExportRequest, projectPath: String?, root: URL) async throws -> FaceActReply {
        let studio = MakeStudio(dataRoot: root)
        guard MakeStudio.isRef(request.reference), let meta = try studio.readMeta(request.reference),
              let version = meta.versions.first(where: { String($0.n) == request.version }) else {
            throw failure("make_version_missing", "The selected Make version is absent from its checked shelf.")
        }
        let source = studio.url(request.reference, version)
        let destination: URL
        let accessURL: URL
        switch request.destination {
        case .chosen(let grant, let name):
            guard grant.writable else { throw failure("make_export_read_only", "Choose a writable export destination.") }
            guard !name.isEmpty, name != ".", name != "..", (name as NSString).lastPathComponent == name else {
                throw failure("make_export_filename_invalid", "Choose a single export filename.")
            }
            accessURL = try BodyFaceResources.resolve(grant)
            destination = accessURL.appendingPathComponent(name)
        case .project:
            let name = request.reference + "-v" + request.version + "." + source.pathExtension
            let plan = MakeStudio.exportDestination(projectPath: projectPath, name: name)
            guard let target = plan.target else {
                let directory = try plan.project.map { folder in
                    ResourceGrant(id: UUID(), name: folder.lastPathComponent,
                        bookmark: try folder.bookmarkData(),
                        writable: true)
                }
                return .makeExportChoice(.init(name: name, directory: directory))
            }
            destination = target
            accessURL = target.deletingLastPathComponent()
        }
        let access = accessURL.startAccessingSecurityScopedResource()
        defer { if access { accessURL.stopAccessingSecurityScopedResource() } }
        let result = try MakeStudio.export(source, to: destination, prompt: version.prompt ?? "")
        guard case .saved = result.work, case .saved = result.prompt else {
            throw WireFailure(code: "make_export_unconfirmed", message: "The export did not fully complete.",
                cause: result.message, effects: .unknown)
        }
        return committed(.string(result.message), identities: [request.reference, request.version])
    }

    @concurrent private static func protectedWindows(_ report: ProtectedWindowsReport) async {
        PersonOnlyWindows.updateRenderer(connection: report.connection, windows: report.windows.map { window in
            .init(number: window.number, frame: .init(x: window.frame.x, y: window.frame.y,
                width: window.frame.width, height: window.frame.height))
        }, keyHeld: report.windows.contains(where: \.keyHeld))
    }

    @concurrent private static func overlay(_ number: Int?, connection: UUID) async {
        PersonOnlyWindows.setRendererOverlay(connection: connection, number: number)
    }

    @concurrent private static func removeProtection(_ connection: UUID) async {
        PersonOnlyWindows.removeRenderer(connection: connection)
    }

    nonisolated static func failure(_ code: String, _ message: String, effects: FaceEffects = .none) -> WireFailure {
        .init(code: code, message: message, cause: nil, effects: effects)
    }

    nonisolated static func committed(_ value: PartFace.Value, identities: [String] = []) -> FaceActReply {
        .committed(.init(identities: identities, value: value, revision: nil, effects: .known, publicationFailure: nil))
    }
}

enum BodyFaceResources {
    static func resolve(_ grant: ResourceGrant) throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: grant.bookmark, options: [.withoutUI],
            relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw BodyFaceServices.failure("stale_resource_grant", "Choose the file again; its access grant is stale.") }
        return url
    }
}
