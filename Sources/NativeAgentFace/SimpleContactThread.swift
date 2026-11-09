import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `SimpleContactThread.swift` | Finished contact-thread lines, links, pending rows and body-owned action receipts |

struct SimpleContactThread: View {
    let contactID: String
    let openChat: () -> Void
    @Environment(AppModel.self) private var appModel
    @State private var note: String?
    @State private var sending = false
    @State private var transcriptHandle = TranscriptDocumentHandle()
    private var slot: FaceSlot { appModel.face.slot(.contactThread(contactID)) }
    private var name: String {
        appModel.face.slot(.contacts).select("label." + contactID, as: ContactsFace.self) {
            $0?.contacts.first { $0.id == contactID }?.label
        } ?? contactID
    }

    var body: some View {
        TranscriptDocumentView(sessionID: "contact:" + contactID, presentation: "contact", handle: transcriptHandle)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                SimpleThreadHeader(title: name, subtitle: slot.select("subtitle", as: ContactThreadFace.self) { $0?.subtitle } ?? "Conversation") {
                    if let contact = appModel.face.slot(.contacts).select("contact." + contactID, as: ContactsFace.self, {
                        $0?.contacts.first { $0.id == contactID }
                    }) { SimpleAvatar(contact: contact, size: 36) }
                }
                VStack(alignment: .leading, spacing: 12) {
                    FaceReadStatus(state: slot.select("state", as: ContactThreadFace.self) { $0?.state })
                    linkedChats
                    if let empty = slot.select("empty", as: ContactThreadFace.self, { $0?.emptyText }) {
                        Text(empty).foregroundStyle(.secondary)
                    }
                }.simpleRoomColumn()
            }.padding(.bottom, 12)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    let waiting = slot.select("waiting.ids", as: ContactThreadFace.self) { $0?.waiting.map(\.id) ?? [] }
                    ForEach(waiting, id: \.self) { id in
                        if let row = slot.select("waiting." + id, as: ContactThreadFace.self, { $0?.waiting.first { $0.id == id } }) {
                            FaceView(face: PartFace(sections: [.init(id: "reading", rows: [row])]), door: ReadOnlyFaceDoor(),
                                session: FacePageSession(), retaining: false)
                            SimpleThreadActions(command: slot.select("command." + id, as: ContactThreadFace.self) { $0?.commands[id] })
                        }
                    }
                    let queued = slot.select("queued.ids", as: ContactThreadFace.self) { $0?.queued.map(\.id) ?? [] }
                    ForEach(queued, id: \.self) { id in
                        if let row = slot.select("queued." + id, as: ContactThreadFace.self, { $0?.queued.first { $0.id == id } }) {
                            FaceView(face: PartFace(sections: [.init(id: "reading", rows: [row])]), door: ReadOnlyFaceDoor(),
                                session: FacePageSession(), retaining: false)
                            SimpleThreadActions(command: slot.select("command." + id, as: ContactThreadFace.self) { $0?.commands[id] })
                        }
                    }
                    if let receipt = slot.select("receipt", as: ContactThreadFace.self, { $0?.receipt }) {
                        Text(receipt).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .simpleRoomColumn()
                if let restriction = slot.select("restriction", as: ContactThreadFace.self, { $0?.sendRestriction }) {
                    Text(restriction).foregroundStyle(.secondary).padding()
                } else {
                    SimpleComposer(thread: contactID, placeholder: "Message \(name)", recipient: name, note: note) { text in
                        await send(text)
                    }
                }
            }
        }
        .faceObservation(.key(.contactThread(contactID)))
    }

    private var linkedChats: some View {
        let sessions = slot.select("linkedSessions", as: ContactThreadFace.self) { $0?.linkedSessions ?? [] }
        return ForEach(sessions, id: \.self) { session in
            Button {
                Task {
                    if await appModel.selectChatSession(id: session, userInitiated: true) {
                        openChat()
                    } else { note = appModel.statusText }
                }
            } label: { SessionTitleLabel(sessionID: session) }
        }
    }

    private func send(_ text: String) async -> Bool {
        guard !sending else { return false }
        sending = true
        note = nil
        defer { sending = false }
        do {
            let session = appModel.activeChatSessionId
            transcriptHandle.goToLatest()
            let reply = try await appModel.client.act(.sendContactMessage(
                ContactSendRequest(contact: contactID, text: text, session: session.isEmpty ? nil : session)))
            try reply.checkedContactAcceptance()
            return true
        } catch {
            note = error.localizedDescription
            return false
        }
    }
}

struct SimpleThreadLines: View {
    let slot: FaceSlot
    var body: some View {
        let ids = slot.select("line.ids", as: ContactThreadFace.self) { $0?.lines.map(\.id) ?? [] }
        ForEach(ids, id: \.self) { id in
            if let line = slot.select("line." + id, as: ContactThreadFace.self, { $0?.lines.first { $0.id == id } }) {
                SimpleTranscriptEntry(speaker: line.speaker, text: line.text, at: line.date).equatable()
                if let receipt = line.receipt { Text(receipt).font(.caption).foregroundStyle(.secondary) }
                if let failure = line.failure { Text(failure.localizedDescription).foregroundStyle(.orange).textSelection(.enabled) }
            }
        }
    }
}

/// The body supplies each command's identities; the owner rechecks them before changing a send.
struct SimpleThreadActions: View {
    let command: FaceContactThreadCommand?
    @Environment(AppModel.self) private var appModel
    @State private var busy = false
    @State private var issue: String?
    var body: some View {
        HStack {
            if let command {
                Button(command.label) { perform(command) }.disabled(busy)
            }
            if let issue { Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
    }

    private func perform(_ command: FaceContactThreadCommand) {
        busy = true
        issue = nil
        Task {
            defer { busy = false }
            do {
                let act: FaceAct
                switch command {
                case .stop(let contact, let record): act = .stopContactMessage(contact: contact, record: record)
                case .resend(let contact, let item, let session): act = .resendContactMessage(contact: contact, item: item, session: session)
                }
                _ = try await appModel.client.act(act).checkedValue()
            } catch { issue = error.localizedDescription }
        }
    }
}

extension FaceActReply {
    func checkedContactAcceptance() throws {
        switch self {
        case .accepted: return
        case .failed(let failure), .refused(let failure): throw failure
        default: throw FaceActionFeedback.unexpected("contact send acceptance")
        }
    }
}
