import Cognition
import SwiftUI
import Observation
import CognitiveSubstrate
// Blueprint: | `CognitionProposalsView.swift` | `CognitionProposalsView`: read-only schema lineage from canonical Dream/REM approvals |

struct CognitionProposalsView: View {
    @Environment(AppModel.self) private var appModel
    private var cognition: CognitionViewFacade { appModel.engine.cognitionView }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.lg) {
                Text("Replay schemas are read-only lineage from the canonical Dream/REM approval path.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NativePanel(title: "REM Replay Lineage", systemImage: "point.3.connected.trianglepath.dotted", tint: .green) {
                    schemaProposalsBody(cognition.proposalsDetail?.schemaProposals ?? [])
                }
            }
            .padding(NativeAgentSpacing.xl)
        }
        .navigationTitle("REM Replay Lineage")
        .task {
            let changes = await cognition.changes()
            await cognition.refreshProposals()
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await cognition.refreshProposals()
            }
        }
    }

    @ViewBuilder
    private func schemaProposalsBody(_ proposals: [CognitiveSchemaProposal]) -> some View {
        if proposals.isEmpty {
            Text("No schema proposals from replay.")
                .font(NativeAgentFont.label)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                ForEach(proposals.filter { $0.status == .proposed } + proposals.filter { $0.status != .proposed }, id: \.id) { proposal in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(proposal.title)
                                .font(.caption.weight(.semibold))
                            Text(proposal.body)
                                .font(.caption)
                                .textSelection(.enabled)
                            Text("\(proposal.status.rawValue), \(proposal.target), confidence \(String(format: "%.2f", proposal.confidence))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    Divider()
                }
            }
        }
    }
}
