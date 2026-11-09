import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `MacWorkOverviewDetail.swift` | Shared work facts and document body; approvals and Inbox draw the Inbox page |

struct MacWorkOverviewDetail: View {
    @Environment(AppModel.self) private var appModel
    let reference: WorkOverviewReference
    let onDone: () -> Void
    private var key: FaceKey { .workDetail(kind: reference.kind.rawValue, id: reference.id) }
    private var detail: WorkDetailFace? { appModel.face.slot(key).value(as: WorkDetailFace.self) }
    var body: some View {
        PageSheetHost(title: detail?.title, onDone: onDone) {
            if reference.kind == .approval || reference.kind == .inbox {
                FacePageView(page: "inbox")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        FaceReadStatus(state: detail?.state)
                        if let detail, let text = detail.text {
                            FaceDocumentContent(text: text, rows: facts(detail))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding()
                }
            }
        }.modifier(FaceObservation(demand: .key(key)))
    }

    private func facts(_ detail: WorkDetailFace) -> [PartFace.Row] {
        var rows: [PartFace.Row] = []
        if let status = detail.status { rows.append(.init(id: "status", title: "Status", value: status)) }
        if let location = detail.location { rows.append(.init(id: "location", title: "Location", value: location)) }
        if let date = detail.sourceDate { rows.append(.init(id: "date", title: "Source updated", value: date.formatted())) }
        return rows
    }
}
