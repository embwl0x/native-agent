import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `ComposerContextReceipt.swift` | Shared receipt rows and demand-read context disclosure from the body |

struct ComposerContextReceiptBody: View {
    let receipt: ContextReceiptFace?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch receipt?.state {
            case .ready?:
                if let receipt {
                    FaceView(face: PartFace(sections: [.init(id: "receipt", style: .values, rows: receipt.rows.map {
                        .init(id: $0.id, title: $0.title, detail: $0.detail)
                    })]), door: ReadOnlyFaceDoor(),
                        session: FacePageSession(), retaining: false)
                }
            case .unavailable(let failure)?: Text(failure.localizedDescription).textSelection(.enabled)
            case .waiting(let on)?: Text("Waiting on " + on + "…")
            case nil: Text("Waiting on the last turn's context…")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("chat.composer.context.card")
        .accessibilityLabel("Context receipt")
    }
}

struct ComposerContextReceiptCard: View {
    let sessionId: String
    let shell: ComposerShellState
    @Environment(AppModel.self) private var appModel
    @State private var disclosed = false
    private var receipt: ContextReceiptFace? {
        appModel.face.slot(.contextReceipt(session: sessionId)).value(as: ContextReceiptFace.self)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ComposerContextReceiptBody(receipt: receipt)
            if receipt?.state == .ready {
                Button(disclosed ? "Hide what I was given" : "Show what I was given") { disclosed.toggle() }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.composer.context.fed.toggle")
                if disclosed {
                    FaceDocumentReader(identity: [sessionId, receipt?.turnId], presentation: { _ in
                        try await appModel.documentPresentation(.context(session: sessionId))
                    }).frame(height: 300)
                }
            }
        }
        .modifier(FaceObservation(demand: sessionId.isEmpty ? nil : .key(.contextReceipt(session: sessionId))))
        .onChange(of: sessionId, initial: true) { _, session in shell.bindContext(session: session, appModel: appModel) }
    }
}
