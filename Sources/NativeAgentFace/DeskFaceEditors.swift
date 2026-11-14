import AppKit
import NativeAgentShared
import SwiftUI
// Blueprint: | `DeskFaceEditors.swift` | Mounted Desk editors await chat draft receipts; notes commit through the body owner |

@MainActor struct DeskFaceEditors: ViewModifier {
    @Environment(AppModel.self) private var appModel
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    private struct NoteTarget: Identifiable {
        let id: String
    }
    /// The Desk's sheets belong to the window, not to one drawing of the page: whichever Desk page is in the window shows them.
    @State private var sheets = DeskWindowPresentation.shared
    func body(content: Content) -> some View { preferenceContent(content) }

    private func preferenceContent(_ content: Content) -> some View {
        @Bindable var sheets = sheets
        let appModel = appModel
        return content
            .onAppear { if !quietOffscreenRead { sheets.receiver = { try await DeskWindowPresentation.shared.take($0, appModel: appModel) } } }
            .onDisappear { if !quietOffscreenRead { sheets.receiver = nil } }
            .sheet(item: Binding(get: { sheets.note.map(NoteTarget.init) }, set: { sheets.note = $0?.id })) { target in
                DeskFaceNoteSheet(handle: target.id)
            }
            .sheet(isPresented: $sheets.newTask) { NewDeskTaskSheet() }
            .sheet(isPresented: $sheets.finding, onDismiss: answerPalette) {
                CommandPaletteView(isPresented: $sheets.finding, desk: DeskPaletteScope(
                    onSelect: select, onCommand: { sheets.paletteAction = $0 }))
            }
            .alert("Desk", isPresented: Binding(get: { sheets.actionMessage != nil }, set: { if !$0 { sheets.actionMessage = nil } })) {
                Button("OK") { sheets.actionMessage = nil }
            } message: {
                Text(sheets.actionMessage ?? "")
            }
            .sheet(item: $sheets.pageSheet) { which in
                DeskPageSheetHost(sheet: which) { sheets.pageSheet = nil }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openCommandPaletteRequest)) { _ in
                guard !quietOffscreenRead else { return }
                sheets.finding = true
            }
    }

    private func select(_ handle: String) {
        appModel.pendingDeskHandle = handle
        Task {
            do { sheets.actionMessage = try FaceWindowReply.message(await appModel.client.act(.deskCommand(.init(
                command: "select", handle: handle, arguments: [:])))) }
            catch { sheets.actionMessage = error.localizedDescription }
        }
    }

    private func answerPalette() {
        guard let command = sheets.paletteAction else { return }
        sheets.paletteAction = nil
        Task {
            do { sheets.actionMessage = try FaceWindowReply.message(await appModel.client.act(.deskCommand(command))) }
            catch { sheets.actionMessage = error.localizedDescription }
        }
    }
}

private struct DeskFaceNoteSheet: View {
    let handle: String
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    private var session: FacePageSession { appModel.pageSessions.page("desk-item/" + handle + "/note") }
    private var call: PartFace.Call { .init("desk.note", ["handle": .string(handle)]) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FaceView(face: PartFace(title: "Add a note", sections: [
                .init(id: "note", rows: [], block: .init(kind: "form", key: "desk-note/" + handle, fields: [
                    .init(id: "text", label: "Note", kind: "lines", value: .string(""), placeholder: "Note…", required: true),
                ], submit: [.init(id: "add", label: "Add", role: .primary, call: call)])),
            ]), door: door, session: session)
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(minWidth: 420).macFaceStyle()
    }

    private var door: ClosureFaceDoor {
        ClosureFaceDoor(open: { _ in }, waitingOn: "the Desk note", perform: { submission in
            guard !submission.checking else {
                return .interrupted(WireFailure(code: "desk_note_unconfirmed",
                    message: "Read this Desk item to check whether the note was added before submitting again.", cause: nil, effects: .unknown))
            }
            guard submission.action == "add", submission.expectedCall == call,
                  let values = submission.values, case .string(let submitted)? = values["text"] else {
                return .interrupted(WireFailure(code: "desk_note_form_invalid",
                    message: "Open the note form again; its text is missing.", cause: nil, effects: .none))
            }
            let text = submitted.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return .interrupted(WireFailure(code: "desk_note_required", message: "Enter a note.", cause: nil, effects: .none,
                                                fields: ["text": "Enter a note."]))
            }
            do {
                let result = try FaceWindowReply.committed(await appModel.client.act(.addDeskNote(handle: handle, text: text)))
                return .init(words: "Note added.", failure: result.publicationFailure, effects: result.effects, accepted: true,
                             committed: [.init(id: "text", value: .string(submitted))])
            } catch { return .interrupted(error) }
        })
    }
}

/// The window's Desk sheets. The renderer's reverse-call router asks through `present`; the Desk page in the window draws what is set here.
@MainActor @Observable final class DeskWindowPresentation {
    static let shared = DeskWindowPresentation()
    var note: String?
    var pageSheet: DeskPageSheet?
    var newTask = false
    var finding = false
    var paletteAction: DeskCommandRequest?
    var actionMessage: String?
    @ObservationIgnored var receiver: ((DeskPresentationRequest) async throws -> String)?

    func present(_ request: DeskPresentationRequest) async throws -> String {
        guard let receiver else {
            throw PartCallError(code: "mac_window_unavailable", message: "Open Desk on the Mac to use this editor or the clipboard.")
        }
        return try await receiver(request)
    }

    func take(_ request: DeskPresentationRequest, appModel: AppModel) async throws -> String {
        guard note == nil, !newTask, pageSheet == nil, !finding else {
            throw PartCallError(code: "editor_in_use", message: "Close the current Desk sheet before opening another Desk editor.")
        }
        switch request {
        case .select(let handle):
            appModel.pendingDeskHandle = handle
            return "Selected the Desk item on the Mac."
        case .findItem:
            finding = true
            return "Opened Find item on the Mac."
        case .newTask:
            newTask = true
            return "Opened New task on the Mac."
        case .note(let handle):
            note = handle
            return "Opened the note editor on the Mac."
        case .research:
            pageSheet = .research
            return "Opened research on the Mac."
        case .reply(let handle):
            let result = try await appModel.prepareChatDraft("About Desk item " + handle)
            guard result.disposition == .applied else {
                throw PartCallError(code: "composer_edit_conflict", message: "The composer changed. Its existing draft was preserved.")
            }
            return "Opened a chat draft about this item on the Mac."
        case .copy(let text):
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(text, forType: .string) else {
                throw PartCallError(code: "clipboard_unavailable", message: "The Mac clipboard did not accept this reference.")
            }
            return "Copied the reference on the Mac."
        }
    }
}
