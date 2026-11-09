import SwiftUI
import NativeAgentShared
// Blueprint: | `ContextFlowObservatoryPanel.swift` | Shared context rows retain the separately held context health owner |

struct ContextFlowObservatoryPanel: View {
    @Environment(AppModel.self) private var appModel
    @State private var session = FacePageSession()
    private var reading: ContextFlowHealthFace? { appModel.face.slot(.contextFlowHealth).value(as: ContextFlowHealthFace.self) }

    var body: some View {
        Group {
            FaceReadStatus(state: reading?.state)
            if let reading {
                FaceView(face: PartFace(title: "Context flow", line: reading.health.rawValue,
                    sections: [.init(id: "context", rows: reading.rows)]), door: ReadOnlyFaceDoor(), session: session)
            }
        }
        .faceObservation(.key(.contextFlowHealth))
    }
}
