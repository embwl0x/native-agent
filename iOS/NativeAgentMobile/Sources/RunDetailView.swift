import SwiftUI
import NativeAgentShared
// Blueprint: | `RunDetailView.swift` | Saved run detail uses the signed document door and shared TextKit renderer |

struct RunDetailView: View {
    let run: RunRecord
    var body: some View { MobileDocumentPage(identity: run, subject: .run(run.id), title: "Run detail") }
}
