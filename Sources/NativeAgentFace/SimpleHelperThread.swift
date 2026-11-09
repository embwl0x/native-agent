import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `SimpleHelperThread.swift` | Helper run rows, full documents and helper-contact messages use body DTOs and acts |

struct SimpleHelperRuns: View {
    let helperID: String
    let openChat: () -> Void
    @Environment(AppModel.self) private var appModel
    @State private var note: String?
    @State private var selectedDocument: DocumentRequest?
    @State private var showingDocument = false
    private var slot: FaceSlot { appModel.face.slot(.helperRuns(helperID)) }
    private var thread: FaceSlot { appModel.face.slot(.contactThread("bot:" + helperID)) }
    private var name: String {
        appModel.face.slot(.helpers).select("name." + helperID, as: HelpersFace.self) { $0?.rows.first { $0.id == helperID }?.title } ?? helperID
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                FaceReadStatus(state: slot.select("state", as: HelperRunsFace.self) { $0?.state })
                let ids = slot.select("ids", as: HelperRunsFace.self) { $0?.runs.map(\.id) ?? [] }
                ForEach(ids, id: \.self) { id in
                    if let row = slot.select("run." + id, as: HelperRunsFace.self, { $0?.runs.first { $0.id == id } }) {
                        Button {
                            selectedDocument = DocumentRequest(id: UUID(), subject: .helperEntry(id))
                            showingDocument = true
                        } label: {
                            FaceView(face: PartFace(sections: [.init(id: "reading", rows: [row])]), door: ReadOnlyFaceDoor(),
                                session: FacePageSession(), retaining: false)
                        }.buttonStyle(.plain)
                    }
                }
                SimpleThreadLines(slot: thread)
                FaceReadStatus(state: thread.select("state", as: ContactThreadFace.self) { $0?.state })
                if let partial = thread.select("partial", as: ContactThreadFace.self, { $0?.partialReply }) {
                    SimpleTranscriptEntry(speaker: name, text: partial, at: nil).equatable()
                }
                let waiting = thread.select("waiting.ids", as: ContactThreadFace.self) { $0?.waiting.map(\.id) ?? [] }
                ForEach(waiting, id: \.self) { id in
                    if let row = thread.select("waiting." + id, as: ContactThreadFace.self, { $0?.waiting.first { $0.id == id } }) {
                        FaceView(face: PartFace(sections: [.init(id: "reading", rows: [row])]), door: ReadOnlyFaceDoor(),
                            session: FacePageSession(), retaining: false)
                        SimpleThreadActions(command: thread.select("command." + id, as: ContactThreadFace.self) { $0?.commands[id] })
                    }
                }
                let queued = thread.select("queued.ids", as: ContactThreadFace.self) { $0?.queued.map(\.id) ?? [] }
                ForEach(queued, id: \.self) { id in
                    if let row = thread.select("queued." + id, as: ContactThreadFace.self, { $0?.queued.first { $0.id == id } }) {
                        FaceView(face: PartFace(sections: [.init(id: "reading", rows: [row])]), door: ReadOnlyFaceDoor(),
                            session: FacePageSession(), retaining: false)
                        SimpleThreadActions(command: thread.select("command." + id, as: ContactThreadFace.self) { $0?.commands[id] })
                    }
                }
                if ids.isEmpty, slot.select("state", as: HelperRunsFace.self, { $0?.state }) == .ready,
                   thread.select("empty", as: ContactThreadFace.self, { $0?.lines.isEmpty }) == true,
                   thread.select("state", as: ContactThreadFace.self, { $0?.state }) == .ready {
                    Text("No runs recorded.").foregroundStyle(.secondary)
                }
                if let receipt = thread.select("receipt", as: ContactThreadFace.self, { $0?.receipt }) {
                    Text(receipt).font(.caption).foregroundStyle(.secondary)
                }
            }.simpleRoomColumn().padding(.vertical, 12)
        }
        .roomTopChrome {
            SimpleThreadHeader(title: name, subtitle: thread.select("subtitle", as: ContactThreadFace.self) { $0?.subtitle } ?? "Helper") {
                SimpleClockTile(size: 36)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SimpleComposer(thread: helperID, placeholder: "Message \(name)", recipient: name, note: note,
                           alternate: ("Ask \(appModel.agentDisplayName)", askAgent)) { await send($0) }
        }
        .sheet(isPresented: $showingDocument) {
            if let selectedDocument { FaceDocumentReadout(request: selectedDocument) }
        }
        .faceObservation(.key(.helperRuns(helperID)))
        .faceObservation(.key(.contactThread("bot:" + helperID)))
    }

    private func send(_ text: String) async -> Bool {
        guard thread.select("running", as: ContactThreadFace.self, { $0?.flight?.isRunning }) != true else {
            note = "\(name) is still answering. Send again once the reply is in."
            return false
        }
        do {
            let session = appModel.activeChatSessionId
            try await appModel.client.act(.sendContactMessage(
                ContactSendRequest(contact: "bot:" + helperID, text: text, session: session.isEmpty ? nil : session)
            )).checkedContactAcceptance()
            note = nil
            return true
        } catch { note = error.localizedDescription; return false }
    }

    private func askAgent(_ text: String) async -> Bool {
        let acceptance = await appModel.startActiveChatTurn("About \(name): \(text)", expectedSessionId: appModel.activeChatSessionId)
        if case .rejected(let message) = acceptance { note = message; return false }
        openChat()
        return true
    }
}
