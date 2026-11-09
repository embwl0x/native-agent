import SwiftUI
import NativeAgentShared
// Blueprint: | `CognitionObservatoryView.swift` | Shared cognition page, context and Desk evidence with retained person commands |

struct CognitionObservatoryView: View {
    @Environment(AppModel.self) private var appModel
    @State private var feedback: String?
    private var session: FacePageSession { appModel.pageSessions.page("cognition") }
    private var snapshot: PartFaceSnapshot? { appModel.face.slot(.page("cognition")).value(as: PartFaceSnapshot.self) }

    var body: some View {
        List {
            if let snapshot {
                FaceView(snapshot: snapshot, title: "Cognition", door: appModel.pageDoor(page: "cognition", open: open), session: session)
            } else { FaceReadStatus(state: .waiting(on: "cognition")) }
            if let feedback { Text(feedback).foregroundStyle(.red).textSelection(.enabled) }
            ContextFlowObservatoryPanel()
            DeskDebugPanels(agentDisplayName: appModel.agentDisplayName)
        }
        .environment(\.faceInList, true)
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .macFaceStyle()
        .faceObservation(.key(.page("cognition")))
        .onAppear { session.notice = { [weak appModel] words in appModel?.systemToasts.push(success: words) } }
    }

    private func open(_ link: String) {
        Task {
            do { _ = try await MacFaceLinks.follow(link, appModel: appModel) { _ in } }
            catch { feedback = error.localizedDescription }
        }
    }
}
