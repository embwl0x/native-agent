// Self-Improvement tab — the home for the weekly WeeklySelfImprovementLoop.
// A simple on/off switch + the latest digest + a manual run. The one-tap
// "apply" proposals surface in Activity → Approvals; this view links there.
import SwiftUI
import Foundation
import BackgroundLoops

struct SelfImprovementView: View {
    // The switch. The weekly loop's gate reads this exact key from
    // UserDefaults.standard (see makeWeeklySelfImprovementLoop).
    @AppStorage("selfImprovementEnabled") private var enabled = false

    @State private var digest: String = ""
    @State private var digestDate: String = ""
    @State private var running = false
    @State private var runNote: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // ── The switch ────────────────────────────────────────────
                Toggle(isOn: $enabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Weekly self-improvement").font(.headline)
                        Text("Once a week, NativeAgent reviews your real usage (chat, errors, health, skills) and proposes safe improvements.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(14)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: NativeAgentRadius.panel))

                Label("Proposals you can apply with one tap appear in Activity → Approvals.",
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
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: NativeAgentRadius.panel))
                }
            }
            .padding()
        }
        .navigationTitle("Self-Improvement")
        .task { loadDigest() }
    }

    @MainActor
    private func runNow() async {
        running = true
        runNote = ""
        // Manual run bypasses the weekly idempotency marker so it actually runs.
        let dataRoot = NativeAgentPaths.dataRoot
        let requestToken: String
        do {
            requestToken = try await WeeklySelfImprovementLoop.requestManualRun(dataRoot: dataRoot)
        } catch {
            running = false
            runNote = "Could not start — the weekly run request is unavailable."
            return
        }
        let outcome = await BackgroundLoopsManager.shared.runTickOnce(
            loopId: "self_improvement_sweep"
        )
        running = false
        runNote = Self.manualRunNote(for: outcome)
        do {
            try await WeeklySelfImprovementLoop.clearManualRunRequest(
                dataRoot: dataRoot,
                token: requestToken
            )
        } catch {
            runNote += " Request cleanup could not be verified: \(NativeClient.safeDoctorDetail(error.localizedDescription))."
        }
        loadDigest()
    }

    static func manualRunNote(for outcome: LoopTickOutcome) -> String {
        switch outcome {
        case .completed:
            return "Done — new proposals (if any) are in Activity → Approvals."
        case .skipped(let reason, _):
            if outcome.isCoalescedSkip {
                return "Already running — joined the active pass."
            }
            return "Not run — \(NativeClient.safeDoctorDetail(reason))."
        case .failed(let error):
            return "Failed — \(NativeClient.safeDoctorDetail(error))."
        }
    }

    private func loadDigest() {
        let dir = NativeAgentPaths.dataRoot
            .appendingPathComponent("self_improvement", isDirectory: true)
            .appendingPathComponent("digests", isDirectory: true)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]),
              let latest = files
                .filter({ $0.pathExtension == "md" })
                .max(by: { a, b in
                    let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    return da < db
                }),
              let text = try? String(contentsOf: latest, encoding: .utf8)
        else { digest = ""; digestDate = ""; return }
        digest = text
        digestDate = latest.deletingPathExtension().lastPathComponent
    }
}
