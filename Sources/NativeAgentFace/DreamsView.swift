import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `DreamsView.swift` | Shared diary selection, owner-held entry demands and the diary's checked cycle levers |

struct DreamsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.quietOffscreenRead) private var offscreen
    @State private var selectedDate: String?
    private var session: FacePageSession { appModel.pageSessions.page("dreams") }
    private var snapshot: PartFaceSnapshot? { appModel.face.slot(.page("dreams")).value(as: PartFaceSnapshot.self) }

    var body: some View {
        Group {
            if let snapshot, let face = presentation(snapshot) {
                FaceSelectionView(face: face, session: session, selection: $selectedDate,
                    door: appModel.pageDoor(page: "dreams", open: open), page: "dreams") { item, _ in
                    AnyView(FaceItemView(item: item, revision: face.sections.first(where: { $0.id == "entries" })?.revision,
                        door: appModel.pageDoor(page: "dreams/" + item, open: open),
                        reader: appModel.pageDoor(page: "dreams", open: open),
                        session: appModel.pageSessions.page("dreams/" + item)))
                }
            } else if let snapshot {
                FaceView(snapshot: snapshot, title: "Dreams", door: appModel.pageDoor(page: "dreams", open: open), session: session)
            } else { Text("Waiting on the dream diary…").foregroundStyle(.secondary) }
        }
        .faceObservation(.key(.page("dreams")))
        .onChange(of: appModel.pendingPaletteDestination, initial: true) { _, destination in
            guard !offscreen, case .dream(let date)? = destination else { return }
            selectedDate = date
            appModel.pendingPaletteDestination = nil
        }
        .navigationTitle("Dreams")
    }

    private func presentation(_ snapshot: PartFaceSnapshot) -> PartFace? {
        guard var face = snapshot.drawnFace else { return nil }
        face.sections += snapshot.levers ?? []
        return face
    }

    private func open(_ link: String) {
        if case .page("dreams", let item?)? = FaceLink(link) { selectedDate = item }
        else if case .dream(let date)? = FaceLink(link) { selectedDate = date }
    }
}

enum DreamsActionFeedback: Equatable {
    case completed(PartFace.Value)
    case failed(String)
    var message: String {
        switch self {
        case .completed(.string(let message)): message
        case .completed(let value): value.text
        case .failed(let message): message
        }
    }
    var isSuccess: Bool {
        if case .completed = self { return true }
        return false
    }
}
