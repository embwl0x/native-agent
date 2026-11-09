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
    @State private var note: NoteTarget?
    @State private var pageSheet: DeskPageSheet?
    @State private var newTask = false
    @State private var finding = false
    @State private var paletteAction: DeskCommandRequest?
    @State private var actionMessage: String?
    func body(content: Content) -> some View { preferenceContent(content) }

    private func preferenceContent(_ content: Content) -> some View {
        content
            .onAppear { if !quietOffscreenRead { DeskWindowPresentation.shared.receiver = request } }
            .onDisappear { if !quietOffscreenRead { DeskWindowPresentation.shared.receiver = nil } }
            .sheet(item: $note) { target in DeskFaceNoteSheet(handle: target.id) }
            .sheet(isPresented: $newTask) { NewDeskTaskSheet() }
            .sheet(isPresented: $finding, onDismiss: answerPalette) {
                CommandPaletteView(isPresented: $finding, desk: DeskPaletteScope(
                    onSelect: select, onCommand: { paletteAction = $0 }))
            }
            .alert("Desk", isPresented: Binding(get: { actionMessage != nil }, set: { if !$0 { actionMessage = nil } })) {
                Button("OK") { actionMessage = nil }
            } message: {
                Text(actionMessage ?? "")
            }
            .sheet(item: $pageSheet) { which in
                DeskPageSheetHost(sheet: which) { pageSheet = nil }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openCommandPaletteRequest)) { _ in
                guard !quietOffscreenRead else { return }
                finding = true
            }
    }

    private func select(_ handle: String) {
        appModel.pendingDeskHandle = handle
        Task {
            do { actionMessage = try FaceWindowReply.message(await appModel.client.act(.deskCommand(.init(
                command: "select", handle: handle, arguments: [:])))) }
            catch { actionMessage = error.localizedDescription }
        }
    }

    private func answerPalette() {
        guard let command = paletteAction else { return }
        paletteAction = nil
        Task {
            do { actionMessage = try FaceWindowReply.message(await appModel.client.act(.deskCommand(command))) }
            catch { actionMessage = error.localizedDescription }
        }
    }

    private func request(_ request: DeskPresentationRequest) async throws -> String {
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
            note = NoteTarget(id: handle)
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

/// The renderer's reverse-call router invokes this mounted receiver.
@MainActor final class DeskWindowPresentation {
    static let shared = DeskWindowPresentation()
    var receiver: ((DeskPresentationRequest) async throws -> String)?
    func present(_ request: DeskPresentationRequest) async throws -> String {
        guard let receiver else {
            throw PartCallError(code: "mac_window_unavailable", message: "Open Desk on the Mac to use this editor or the clipboard.")
        }
        return try await receiver(request)
    }
}
