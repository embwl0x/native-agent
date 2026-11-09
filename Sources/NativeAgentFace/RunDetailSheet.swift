import SwiftUI
import NativeAgentShared
// Blueprint: | `RunDetailSheet.swift` | Saved run detail uses the shared document demand and TextKit renderer |

struct RunDetailSheet: View {
    let run: RunRecord
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var appModel

    var body: some View {
        PageSheetHost(title: "Run detail", onDone: { dismiss() }) {
            FaceDocumentReader(identity: run, presentation: { _ in try await appModel.documentPresentation(.run(run.id)) }).padding(16)
        }
    }
}
