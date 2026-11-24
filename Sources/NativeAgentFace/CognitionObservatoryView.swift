import SwiftUI
import NativeAgentShared
// Blueprint: | `CognitionObservatoryView.swift` | Shared cognition page, context and Desk evidence with retained person commands |

struct CognitionObservatoryView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    @State private var feedback: String?
    @State private var activityTarget: ActivityTarget?
    private var session: FacePageSession { appModel.pageSessions.page("cognition") }
    private var snapshot: PartFaceSnapshot? { appModel.face.slot(.page("cognition")).value(as: PartFaceSnapshot.self) }

    private struct ActivityTarget: Identifiable {
        let reference: WorkOverviewReference
        var id: String { reference.kind.rawValue + ":" + reference.id }
    }

    var body: some View {
        let face = snapshot?.status == .ready ? snapshot?.face : nil
        VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
            AlivePageHeader(title: face?.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Cognition", line: face?.line, wrapsLine: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .frame(maxWidth: TodayMetrics.contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            ScrollView {
                VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                    if let snapshot {
                        FaceView(snapshot: snapshot, title: "Cognition", header: false,
                                 door: appModel.pageDoor(page: "cognition", open: open), session: session)
                    } else { FaceReadStatus(state: .waiting(on: "cognition")) }
                    if let feedback { Text(feedback).foregroundStyle(.red).textSelection(.enabled) }
                    ContextFlowObservatoryPanel()
                    DeskDebugPanels(agentDisplayName: appModel.agentDisplayName)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, quietOffscreenRead ? 32 : 48)
                .frame(maxWidth: TodayMetrics.contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .pageScrollColumn()
            .scrollEdgeEffectStyle(quietOffscreenRead ? nil : .soft, for: [.top, .bottom])
        }
        .padding(.top, TodayMetrics.topPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .faceObservation(.key(.page("cognition")))
        .sheet(item: $activityTarget) { target in
            MacWorkOverviewDetail(reference: target.reference) { activityTarget = nil }
        }
    }

    private func open(_ link: String) {
        feedback = nil
        Task {
            do { _ = try await MacFaceLinks.follow(link, appModel: appModel) { activityTarget = ActivityTarget(reference: $0) } }
            catch { feedback = error.localizedDescription }
        }
    }
}
