import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `MemoryView.swift` | Memory upkeep acts, full text, feed read status and scoped face observations |

struct MemoryUpkeepPanel: View {
    @Environment(AppModel.self) private var appModel
    private var session: FacePageSession { appModel.pageSessions.page("memory-upkeep") }
    private var snapshot: PartFaceSnapshot? { appModel.face.slot(.page("memory-upkeep")).value(as: PartFaceSnapshot.self) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EmbeddingModelDownloadRow()
            if let snapshot {
                FaceView(snapshot: snapshot, title: "Memory upkeep", door: appModel.pageDoor(page: "memory-upkeep", open: { _ in }), session: session)
            } else { Text("Waiting on memory diagnostics…").foregroundStyle(.secondary) }
        }
        .faceObservation(.key(.page("memory-upkeep")))
        .onAppear { session.notice = { [weak appModel] words in appModel?.systemToasts.push(success: words) } }
    }
}

extension View {
    func faceObservation(_ demand: FaceDemand) -> some View { modifier(FaceObservation(demand: demand)) }
}
