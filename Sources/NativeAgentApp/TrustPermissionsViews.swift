import EngineRuntime
import SwiftUI
import NativeAgentShared
import PersistenceCore
import ChromeControl
import MacControl
import TrustCenter
import ChatTurnRuntime
import ChatTurnContracts

// Blueprint: | `TrustPermissionsViews.swift` | Shared Settings memory permissions and feature-switch rows; Trust permission controls live in its face |

struct LivingMemoryPermissionsView: View {
    @Environment(AppModel.self) private var appModel
    private var policy: TrustMemoryPolicy? { appModel.engine.trust.memoryPermissions }
    @State private var isSaving = false

    private var pendingCount: Int {
        appModel.engine.memory.proposals.filter { $0.status == "pending" }.count
    }

    /// Let the containing page own the group card so shared memory controls do not nest plates.
    var body: some View {
        Group {
            FeatureSwitchRow(
                title: "Remember across conversations",
                detail: "Each time you write, I look through all our past conversations for what is relevant. Read only; on by default.",
                identifier: "setup.feature.cross_session_recall",
                isOn: Binding(
                    get: { policy?.cross_session_recall == true },
                    set: { v in
                        guard var next = policy else { return }
                        next.cross_session_recall = v
                        Task { await saveMemoryPolicy(next) }
                    }
                )
            )
            FeatureSwitchRow(
                title: "Knowledge graph",
                detail: "I join up the people, places and things your conversations keep mentioning, and draw them in Memory → Graph.",
                identifier: "setup.feature.knowledge_graph_enabled",
                isOn: Binding(
                    get: { policy?.knowledge_graph_enabled == true },
                    set: { v in
                        Task { await patchMemoryPolicy(knowledgeGraph: v) }
                    }
                )
            )
            FeatureSwitchRow(
                title: "Recurring memories are proposed as facts",
                detail: "When something useful keeps coming back, I suggest keeping it as a lasting fact, without loading all my memory into every reply.",
                identifier: "setup.feature.adaptive_promotion",
                isOn: Binding(
                    get: { policy?.adaptive_promotion == true },
                    set: { v in
                        Task { await patchMemoryPolicy(adaptivePromotion: v) }
                    }
                )
            )
            if policy == nil {
                FeatureNote("Memory settings unavailable. Reload Settings to read the saved policy.")
            }
            if pendingCount > 0 {
                HStack(spacing: 8) {
                    AliveWaitingDot()
                    Text("\(pendingCount) memory suggestion\(pendingCount == 1 ? "" : "s") waiting for you in Memory")
                        .font(ShellType.labelMedium)
                        .foregroundStyle(NativeAgentShell.text)
                }
            }
            FeatureNote("""
                What I remember and how I recall it are set here. Suggested memory changes wait for you in Memory; suggested changes to \
                how I behave wait in Self-Improvement.
                """)
        }
        .disabled(isSaving || policy == nil)
    }

    private func saveMemoryPolicy(_ policy: TrustMemoryPolicy) async {
        isSaving = true
        await appModel.saveMemoryPolicy(
            crossSessionRecall: policy.cross_session_recall
        )
        isSaving = false
    }

    private func patchMemoryPolicy(knowledgeGraph: Bool? = nil, adaptivePromotion: Bool? = nil) async {
        isSaving = true
        await appModel.patchMemoryPolicy(
            knowledgeGraphEnabled: knowledgeGraph,
            adaptivePromotion: adaptivePromotion
        )
        isSaving = false
    }
}

struct FeatureSwitchRow: View {
    let title: String
    var detail: String? = nil
    var note: String? = nil
    var identifier: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(ShellType.rowTitle)
                    .foregroundStyle(NativeAgentShell.text)
                if let detail {
                    Text(detail)
                        .font(ShellType.rowDetail)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note {
                    Text(note)
                        .font(ShellType.rowDetail)
                        .foregroundStyle(NativeAgentShell.secondary)
                }
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .hazeTinted()
                .accessibilityIdentifier(identifier ?? "")
        }
    }
}

private struct FeatureNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(ShellType.rowDetail)
            .foregroundStyle(NativeAgentShell.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
