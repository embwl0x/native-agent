import SwiftUI
import NativeAgentShared
// Blueprint: | `CognitionProposalsView.swift` | Canonical proposal lineage uses the shared page rows and its held cognition read |

struct CognitionProposalsView: View {
    @Environment(AppModel.self) private var appModel
    private var reading: CognitionFace? { appModel.face.slot(.cognition).value(as: CognitionFace.self) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.lg) {
                FaceReadStatus(state: reading?.state)
                if let reading {
                    Text("Replay schemas are read-only lineage from the canonical Dream/REM approval path.")
                        .foregroundStyle(.secondary)
                    ForEach(reading.proposals) { row in FaceDocumentContent(row: row) }
                }
            }.padding(NativeAgentSpacing.xl)
        }
        .navigationTitle("REM Replay Lineage")
        .faceObservation(.key(.cognition))
    }
}
