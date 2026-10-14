import EngineRuntime
import PersistenceCore
import BackgroundWork
// Self-Improvement tab — the home for the weekly WeeklySelfImprovementLoop.
// A simple on/off switch + the latest digest + a manual run. The one-tap
// "apply" proposals surface in Approvals (Today ▸ Approvals and past
// decisions).
import AttentionRouting
import SwiftUI
import Foundation
import BackgroundLoops
import MemoryV2

struct SelfImprovementView: View {
    @Environment(AppModel.self) private var appModel
    // The switch. The weekly loop's gate reads this exact key from
    // UserDefaults.standard (see makeWeeklySelfImprovementLoop).
    @AppStorage("selfImprovementEnabled") private var enabled = true

    @State private var digest: String = ""
    @State private var digestDate: String = ""
    @State private var running = false
    @State private var runNote: String = ""

    var body: some View {
        // Render-cost audit: same env-gated counter as `contentview.body`.
        RenderAudit.bump("selfimprovement.body")
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // ── Misses ────────────────────────────────────────────────
                // What she was corrected on, by lesson, this week against
                // last: the growth metric. A row opens the conversation.
                Text("Misses").font(.headline)
                if appModel.missLessons.isEmpty {
                    Text(appModel.panelRefreshStatus[.activity]?.failedEndpoints.contains("misses") == true
                         ? "The miss ledger could not be read." : "No corrections this week or last.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(appModel.missLessons) { lesson in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(lesson.lesson).font(.callout.weight(.semibold))
                            Spacer()
                            Text("\(lesson.count(week: MemoryStatusProjection.isoWeek())) this week · "
                                 + "\(lesson.count(week: MemoryStatusProjection.isoWeek(ago: 1))) last week")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(lesson.misses) { miss in
                            Button(miss.text) {
                                if let session = miss.sessionId {
                                    Task { await NativeAgentNotificationActions.openConversation(
                                        session, messageID: miss.history.map { String($0.dropFirst("history:".count)) }) }
                                }
                            }
                            .buttonStyle(.link)
                            .lineLimit(1)
                            .disabled(miss.sessionId == nil)
                            .help(miss.history ?? "Kept before corrections carried their turn.")
                        }
                    }
                }
                Divider()

                // ── The switch ────────────────────────────────────────────
                Toggle(isOn: $enabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Weekly self-improvement").font(.headline)
                        Text("Once a week, NativeAgent reviews your real usage (chat, errors, health, skills) and proposes safe improvements.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .hazeTinted()
                .padding(14)
                .houseInset(in: RoundedRectangle(cornerRadius: NativeAgentRadius.panel))

                Label("Proposals you can apply with one tap appear in Approvals on Today.",
                      systemImage: "checkmark.seal")
                    .font(.callout).foregroundStyle(.secondary)

                // ── Manual run ────────────────────────────────────────────
                HStack(spacing: 10) {
                    Button {
                        Task { await runNow() }
                    } label: {
                        Label(running ? "Running…" : "Run now", systemImage: "wand.and.stars")
                    }
                    .disabled(!enabled || running)
                    if !runNote.isEmpty {
                        Text(runNote).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Divider()

                // ── Latest digest ─────────────────────────────────────────
                HStack {
                    Text("Latest digest").font(.headline)
                    Spacer()
                    if !digestDate.isEmpty {
                        Text(digestDate).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if digest.isEmpty {
                    Text(enabled
                         ? "No run yet. Tap Run now, or wait for the weekly pass."
                         : "Turn self-improvement on to start the weekly pass.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(digest)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .houseInset(in: RoundedRectangle(cornerRadius: NativeAgentRadius.panel))
                }
            }
            .padding()
        }
        .navigationTitle("Self-Improvement")
        .task { await loadDigest() }
    }

    @MainActor
    private func runNow() async {
        running = true
        runNote = ""
        runNote = await Self.runManually(appModel: appModel).note
        running = false
        await loadDigest()
    }

    /// The Run now pass, shared with the agent's `mind_run self_improvement`.
    /// Nil outcome: the run never started.
    @MainActor
    static func runManually(appModel: AppModel) async -> (outcome: LoopTickOutcome?, note: String) {
        let result = await WeeklySelfImprovementLoop.runManually(dataRoot: PersistenceCore.defaultDataRoot()) {
            await NativeAgentEngine.runBackgroundLoopOnce(loopId: "self_improvement_sweep")
        }
        guard let outcome = result.outcome else {
            return (nil, "Could not start — the weekly run request is unavailable.")
        }
        var note = manualRunNote(for: outcome)
        if let error = result.cleanupError {
            note += " Request cleanup could not be verified: \(EngineDoctorRuntime<AppDoctorPort>.safeDetail(error))."
        }
        // The pass may have staged new candidates; re-read the queues.
        _ = await appModel.refreshForSidebarItem(.activity)
        return (outcome, note)
    }

    static func manualRunNote(for outcome: LoopTickOutcome) -> String {
        switch outcome {
        case .completed:
            return "Done — new proposals (if any) are in Approvals on Today."
        case .skipped(let reason, _):
            if outcome.isCoalescedSkip {
                return "Already running — joined the active pass."
            }
            return "Not run — \(EngineDoctorRuntime<AppDoctorPort>.safeDetail(reason))."
        case .failed(let error):
            return "Failed — \(EngineDoctorRuntime<AppDoctorPort>.safeDetail(error))."
        }
    }

    private func loadDigest() async {
        let loaded = await WeeklySelfImprovementLoop.latestDigest(dataRoot: PersistenceCore.defaultDataRoot())
        digest = loaded?.text ?? ""
        digestDate = loaded?.date ?? ""
    }
}
