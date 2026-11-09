import SwiftUI
import NativeAgentShared
// Blueprint: | `DeskDebugPanels.swift` | Finished body Desk diagnostics |

struct DeskDebugPanels: View {
    @Environment(AppModel.self) private var appModel
    let agentDisplayName: String
    private var diagnostics: DeskDiagnosticsFace? { appModel.face.slot(.deskDiagnostics).value(as: DeskDiagnosticsFace.self) }
    var body: some View {
        Group {
            FaceReadStatus(state: diagnostics?.state)
            if let diagnostics {
                DisclosureGroup(agentDisplayName + "'s Desk (debug)") {
                    ForEach(diagnostics.rows) { row in
                        FaceDocumentContent(row: row, format: "code")
                    }
                }
            }
        }.modifier(FaceObservation(demand: .key(.deskDiagnostics)))
    }
}
