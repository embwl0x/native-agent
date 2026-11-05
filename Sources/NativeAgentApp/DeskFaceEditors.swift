import AppKit
import AuthoredCapabilities
import Cognition
import Desk
import EngineRuntime
import NativeAgentShared
import SwiftUI
// Blueprint: | `DeskFaceEditors.swift` | Mounted Mac adapters for Desk face editor requests; note drafts use the existing Desk tool router |

@MainActor struct DeskFaceEditors: ViewModifier {
    @Environment(AppModel.self) private var appModel
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    private struct NoteTarget: Identifiable {
        let id: String
    }
    private struct PaletteAction {
        let handle: String
        let action: String
        var value: String? = nil
    }
    @State private var note: NoteTarget?
    @State private var pageSheet: DeskPageSheet?
    @State private var newTask = false
    @State private var finding = false
    @State private var paletteAction: PaletteAction?
    @State private var actionMessage: String?
    @AppStorage(StudioWanderLane.enabledDefaultsKey) private var studioWanderEnabled = StudioWanderLane.enabledByDefault
    @AppStorage("cognitiveSubstrateEnabled") private var cognitiveSubstrateEnabled = true

    func body(content: Content) -> some View {
        content
            .onAppear { if !quietOffscreenRead { appModel.engine.desk.faceRequest = request } }
            .onDisappear { if !quietOffscreenRead { appModel.engine.desk.faceRequest = nil } }
            .onChange(of: studioWanderEnabled) { Task { await appModel.engine.desk.signalRefresh() } }
            .onChange(of: cognitiveSubstrateEnabled) { Task { await appModel.engine.desk.signalRefresh() } }
            .sheet(item: $note) { target in DeskFaceNoteSheet(handle: target.id) }
            .sheet(isPresented: $newTask) { NewDeskTaskSheet() }
            .sheet(isPresented: $finding, onDismiss: answerPalette) {
                CommandPaletteView(isPresented: $finding, desk: DeskPaletteScope(
                    rows: DeskPageContent.active(appModel.engine.desk.page.boardItems).map(DeskPaletteRow.init(item:)),
                    selectedHandle: appModel.engine.desk.faceItem,
                    onSelect: { appModel.engine.desk.faceItem = $0 }, onCommand: paletteCommand))
            }
            .alert("Desk", isPresented: Binding(get: { actionMessage != nil }, set: { if !$0 { actionMessage = nil } })) {
                Button("OK") { actionMessage = nil }
            } message: {
                Text(actionMessage ?? "")
            }
            .sheet(item: $pageSheet) { which in
                DeskPageSheetHost(sheet: which) { pageSheet = nil }
            }
            .onReceive(NotificationCenter.default.publisher(for: .deskTaskCreated)) { _ in
                guard !quietOffscreenRead else { return }
                Task { _ = await appModel.engine.desk.refreshPage() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openCommandPaletteRequest)) { _ in
                guard !quietOffscreenRead else { return }
                finding = true
            }
    }

    private func paletteCommand(_ verb: DeskPaletteQuery.Verb, handle: String) {
        let desk = appModel.engine.desk
        switch DeskPaletteCommandApplication.resolve(verb: verb, handle: handle,
            activeItems: DeskPageContent.active(desk.page.boardItems)) {
        case .dispatch(let action):
            paletteAction = PaletteAction(handle: handle, action: "close", value: action.input["expected_updated_at"]?.stringValue)
        case .beginDefer(let handle):
            // The selected item's face offers every defer choice, with the same owner behind each button.
            desk.faceItem = handle
        case .beginNote(let handle):
            desk.faceItem = handle
            paletteAction = PaletteAction(handle: handle, action: "note")
        case .refused(let message):
            actionMessage = message
        }
    }

    private func answerPalette() {
        guard let pending = paletteAction else { return }
        paletteAction = nil
        Task {
            do {
                let words = try await appModel.engine.pages.act(page: "desk", row: pending.handle, action: pending.action,
                    value: pending.value, by: .person(door: "mac"))
                if pending.action != "note" { actionMessage = words }
            } catch {
                actionMessage = error.localizedDescription
            }
        }
    }

    private func request(_ request: DeskFaceRequest) throws -> String {
        guard note == nil, !newTask, pageSheet == nil, !finding else {
            throw PartCallError(code: "editor_in_use", message: "Close the current Desk sheet before opening another Desk editor.")
        }
        switch request {
        case .findItem:
            finding = true
            return "Opened Find item on the Mac."
        case .newTask:
            newTask = true
            return "Opened New task on the Mac."
        case .note(let handle):
            note = NoteTarget(id: handle)
            return "Opened the note editor on the Mac."
        case .schedule:
            pageSheet = .schedule
            return "Opened the schedule on the Mac."
        case .research:
            pageSheet = .research
            return "Opened research on the Mac."
        case .reply(let draft):
            NotificationCenter.default.post(name: .openChatDraftRequest, object: draft)
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
    @State private var submitting = false
    @State private var errorMessage: String?
    private var subject: String { "desk-item/" + handle + "/note" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a note").font(.headline)
            TextField("Note…", text: appModel.editBinding(subject, seed: ""), axis: .vertical)
                .lineLimit(3...8).textFieldStyle(.roundedBorder).disabled(submitting)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.disabled(submitting)
                Button("Add") { submit() }.disabled(submitting || appModel.editDraft(subject, seed: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(minWidth: 420).interactiveDismissDisabled(submitting)
    }

    private func submit() {
        let submitted = appModel.editDraft(subject, seed: "")
        submitting = true
        errorMessage = nil
        Task {
            let outcome = await DeskToolDispatchRouter(dataRoot: appModel.engine.dataRoot)
                .perform(.note(handle: handle, text: submitted.trimmingCharacters(in: .whitespacesAndNewlines)))
            _ = await appModel.engine.desk.refreshPage()
            submitting = false
            guard outcome.ok else { errorMessage = outcome.message; return }
            if appModel.editDraft(subject, seed: "") == submitted { appModel.clearEditDraft(subject) }
            dismiss()
        }
    }
}
