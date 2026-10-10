// Self-Improvement tab — the home for the weekly WeeklySelfImprovementLoop.
// A simple on/off switch + the latest digest + a manual run. The one-tap
// "apply" proposals surface in Approvals (Today ▸ Approvals and past
// decisions).
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
        // Manual run bypasses the weekly idempotency marker so it actually runs.
        let dataRoot = NativeAgentPaths.dataRoot
        let requestToken: String
        do {
            requestToken = try await WeeklySelfImprovementLoop.requestManualRun(dataRoot: dataRoot)
        } catch {
            return (nil, "Could not start — the weekly run request is unavailable.")
        }
        let outcome = await BackgroundLoopsManager.shared.runTickOnce(
            loopId: "self_improvement_sweep"
        )
        var note = manualRunNote(for: outcome)
        do {
            try await WeeklySelfImprovementLoop.clearManualRunRequest(
                dataRoot: dataRoot,
                token: requestToken
            )
        } catch {
            note += " Request cleanup could not be verified: \(AppDoctorPort.safeDetail(error.localizedDescription))."
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
            return "Not run — \(AppDoctorPort.safeDetail(reason))."
        case .failed(let error):
            return "Failed — \(AppDoctorPort.safeDetail(error))."
        }
    }

    /// Newest-wins selection over already-stat'ed candidates. Extracted from
    /// `loadDigest` so the ordering rule is testable without a filesystem, and
    /// so each file is stat'ed once instead of twice per `max(by:)` comparison.
    /// Semantics are unchanged: latest modification date wins; ties keep the
    /// earlier element in enumeration order (`max(by:)` only replaces on a
    /// strict increase); an unreadable date is `.distantPast` at the call site.
    nonisolated static func newestDigest(_ dated: [(url: URL, modified: Date)]) -> URL? {
        dated.max(by: { $0.modified < $1.modified })?.url
    }

    /// Render-cost audit F4: this used to be a synchronous MainActor method —
    /// a directory enumeration, O(n log n) stat syscalls, and a full digest
    /// read, all blocking the main thread on every appear. Same work, same
    /// result, now on a utility thread. `digest` already starts empty, so the
    /// pre-load frame is the one that always rendered first anyway.
    private func loadDigest() async {
        let dir = NativeAgentPaths.dataRoot
            .appendingPathComponent("self_improvement", isDirectory: true)
            .appendingPathComponent("digests", isDirectory: true)
        let loaded = await Task.detached(priority: .utility) { () -> (text: String, date: String)? in
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            else { return nil }
            let dated = files
                .filter { $0.pathExtension == "md" }
                .map { url -> (url: URL, modified: Date) in
                    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    return (url, modified)
                }
            guard let latest = SelfImprovementView.newestDigest(dated),
                  let text = try? String(contentsOf: latest, encoding: .utf8)
            else { return nil }
            return (text, latest.deletingPathExtension().lastPathComponent)
        }.value
        digest = loaded?.text ?? ""
        digestDate = loaded?.date ?? ""
    }
}
