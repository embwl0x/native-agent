import SwiftUI
import AppKit
import NativeAgentShared
import StandingBots
import Foundation
import NativeAgentCore
import EngineRuntime
import Transcripts
import TurnTrace
import ChatTurnRuntime
import ChatSessionWork
import ToolExecution
import MemoryV2
import AppToolRuntime
import ApprovalTransactions
import PersistenceCore
import ToolRegistry
import ProviderRouting
import DoctorChecks
import Research
import TelegramBot
import Connectors
import AttentionRouting
import WidgetKit
import AppIntents
import Observation
import BackgroundLoops
import PersonaEngine
import TrustCenter
import MultimodalTTS
import SystemOps
import DeviceSync
import BackgroundWork
import ChatToolRuntime
import ApprovalInbox
import MacControl
import ChatToolParsing
import UniformTypeIdentifiers
import Desk
// Blueprint: | `BotRunCard.swift` | Helper run receipts, quiet-run folds and artifact links; recorded outcomes and model remain run-owned |

/// One settled run, summarized: the headline the reply opened with, when the
/// run happened and how long it took, the outcome word, the model it ran on,
/// and whatever the reply produced. The full reply is behind "Open the reply";
/// the session transcript stays below the cards.
struct BotRunCard: View {
    /// How many settled cards the detail stacks before the transcript.
    static let shown = 5
    let entry: ShelfEntry

    /// Use the recorded headline when an actual reply exists.
    private var headline: String {
        // Trust a stored headline only when actualReply is nonempty.
        guard !entry.actualReply.isEmpty else {
            switch entry.runtimeStatus {
            case .completed:
                return entry.runHealth == .nothingNew ? "Checked, nothing new" : "Nothing saved"
            case .waitingForApproval:
                return "Waiting for approval — no reply yet"
            case .waitingOnPerson:
                return "Waiting on you — no reply yet"
            case .failed, .stopped, .interrupted:
                // The recorded cause, said once, with the absence stated.
                return (causeStem.isEmpty ? outcome : causeStem) + " — no reply"
            }
        }
        if !entry.headline.isEmpty { return BotHeadline.make(from: entry.headline) }
        return BotHeadline.make(from: entry.actualReply)
    }
    /// The recorded cause as one clean clause, without its full stop.
    private var causeStem: String {
        let recorded = [entry.statusDetail, entry.uncertainties.first]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return recorded.split(separator: ".").first
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }
    /// One word for how the run ended, never a verdict on the task.
    private var outcome: String {
        switch entry.runtimeStatus {
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        case .interrupted: return "Interrupted"
        case .waitingForApproval: return "Blocked"
        case .waitingOnPerson: return "Waiting"
        }
    }
    private var duration: String? {
        let seconds = entry.spend.seconds
        guard seconds.isFinite, seconds >= 0 else { return "Invalid duration" }
        guard seconds > 0 else { return nil }
        if seconds < 1 { return "<1s" }
        if seconds < 60 { return String(format: "%.0fs", seconds.rounded()) }
        let whole = seconds.rounded()
        let minutes = (whole / 60).rounded(.down)
        let remainder = whole.truncatingRemainder(dividingBy: 60)
        return remainder == 0 ? String(format: "%.0fm", minutes)
            : String(format: "%.0fm %.0fs", minutes, remainder)
    }
    /// Missing run-time model evidence stays explicitly unknown.
    private var model: String { entry.model ?? "Model not recorded" }
    /// The recorded cause when a run did not complete; never invented.
    private var cause: String? {
        guard entry.runtimeStatus != .completed else { return nil }
        let recorded = [entry.statusDetail, entry.uncertainties.first]
            .compactMap { $0 }.first { !$0.isEmpty && $0 != headline }
        return recorded ?? "Cause not recorded."
    }
    private var artifacts: [BotArtifact] { entry.artifacts ?? [] }
    /// How the run ended and when — the row's name to a reader.
    private var spokenOutcome: String {
        [outcome, BotsShelfRecord.shortDate(entry.runAt), duration]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
    /// What the run actually said, plus the cause when it did not complete and
    /// the model it ran on. Stated here because a stack of styled Texts
    /// publishes no words when the page is read offscreen.
    private var spokenSummary: String {
        [headline, cause, model].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: ". ")
    }

    /// A settled run wears one of the family's three marks: done, or — for a
    /// run that failed, was stopped, or is still blocked — the yellow mark that
    /// means "this did not land, or I cannot say it did". A bot run is never
    /// "declined": nobody refused it.
    private var mark: InlineCardMark {
        entry.runtimeStatus == .completed ? .done : .unknown
    }

    /// Date, duration and the model it ran on — the metadata the settled
    /// receipt carries beside the outcome.
    private var metaLine: String {
        [outcome, BotsShelfRecord.shortDate(entry.runAt), duration, model]
            .compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    // A shared receipt keeps cause, artifacts and full reply one disclosure away.
    var body: some View {
        InlineCardReceipt(
            mark: mark,
            outcome: headline,
            meta: metaLine,
            detailsLabel: hasDetails ? "Full reply" : nil
        ) {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                if let cause {
                    Text(cause).font(ShellType.caption).foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(artifacts.enumerated()), id: \.offset) { _, artifact in
                    BotsShelfArtifactLink(artifact: artifact)
                }.foregroundStyle(.blue)
                if !entry.actualReply.isEmpty {
                    let reply = entry.actualReply.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let attributed = ChatMarkdownCache.attributed(reply) {
                        Text(attributed).font(ShellType.body).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(reply).font(ShellType.body).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        // `.contain`, not `.ignore`: the row names itself while the disclosure
        // and the artifact links stay reachable.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spokenOutcome)
        .accessibilityValue(spokenSummary)
    }

    /// Whether there is anything behind the fold at all.
    private var hasDetails: Bool {
        !entry.actualReply.isEmpty || cause != nil || !artifacts.isEmpty
    }
}

/// Consecutive checks that found nothing, as one quiet dated row. The count is
/// on the face of it and the exact runs are one disclosure away — a finding a
/// few checks back stays on the card instead of falling into the transcript.
struct BotQuietRunsRow: View {
    let entries: [ShelfEntry]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $open) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(entries) { entry in BotRunCard(entry: entry) }
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(NativeAgentShell.tertiary).frame(width: 7, height: 7)
                    Text(BotRunFeed.quietLine(entries))
                        .font(ShellType.captionMedium)
                        .foregroundStyle(NativeAgentShell.secondary)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .font(ShellType.caption)
            .foregroundStyle(NativeAgentShell.secondary)
        }
        .padding(16).botCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(BotRunFeed.quietLine(entries))
    }
}

private struct BotsShelfArtifactLink: View {
    let artifact: BotArtifact
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading) {
            if !artifact.path.isEmpty {
                if let url = URL(string: artifact.path), let scheme = url.scheme {
                    if ["https", "http", "file"].contains(scheme.lowercased()) { Link(artifact.name, destination: url) }
                    else { Text(artifact.name) }
                } else { Link(artifact.name, destination: URL(fileURLWithPath: artifact.path)) }
            } else if let encoded = artifact.base64, let data = Data(base64Encoded: encoded) {
                Button("Save \(artifact.name)", systemImage: "arrow.down.doc") {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = artifact.name
                    panel.begin { response in
                        guard response == .OK, let url = panel.url else { return }
                        do { try data.write(to: url, options: .atomic) }
                        catch { self.error = UserFacingError.message(error, action: "save that file") }
                    }
                }.buttonStyle(.link)
            } else { Text("\(artifact.name) · File unavailable") }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

extension BotRunFeed {
    /// "Three quiet checks since Sep 10 at 1:47 AM" — the count stays visible.
    static func quietLine(_ entries: [ShelfEntry]) -> String {
        let since = entries.last.map { BotsShelfRecord.shortDate($0.runAt) }
        return "\(TodayWords.spelled(entries.count)) quiet check\(entries.count == 1 ? "" : "s")"
            + (since.map { " since \($0)" } ?? "")
    }
}
