import SwiftUI
import NativeAgentShared
// Blueprint: | `DeskDebugPanels.swift` | Finished body Desk diagnostics |

struct DeskDebugPanels: View {
    @Environment(AppModel.self) private var appModel
    let agentDisplayName: String
    private var session: FacePageSession { appModel.pageSessions.page("cognition/desk-debug") }
    private var diagnostics: DeskDiagnosticsFace? { appModel.face.slot(.deskDiagnostics).value(as: DeskDiagnosticsFace.self) }
    var body: some View {
        Group {
            FaceReadStatus(state: diagnostics?.state)
            if let diagnostics {
                let sections = diagnostics.rows.compactMap { row -> PartFace.Section? in
                    guard let text = row.detail else { return nil }
                    let block = PartFace.Block(key: row.id,
                        text: text.utf8.count <= PartFace.Block.inlineByteLimit ? text : nil,
                        format: "code", copy: true, revision: SHA256Hex.of(utf8: text))
                    return .init(id: row.id, title: row.title, rows: [], folded: true, block: block)
                }
                let face = PartFace(title: agentDisplayName + "'s Desk (debug)", sections: sections)
                let door = ClosureFaceDoor(open: { _ in }, waitingOn: "Desk debug", read: { request in
                    guard let text = diagnostics.rows.first(where: { $0.id == request.key })?.detail,
                          request.revision == SHA256Hex.of(utf8: text) else {
                        throw PartCallError(code: "desk_debug_changed", message: "Desk debug output changed. Open it again.")
                    }
                    return text
                }, perform: { _ in
                    .interrupted(WireFailure(code: "desk_debug_read_only", message: "Desk debug output has no write command.",
                                             cause: nil, effects: .none))
                })
                FaceView(face: face, door: door, session: session)
            }
        }.modifier(FaceObservation(demand: .key(.deskDiagnostics)))
    }
}
