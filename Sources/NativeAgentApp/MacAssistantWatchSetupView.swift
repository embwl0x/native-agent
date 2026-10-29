import SwiftUI
import MacIntegration
import EngineRuntime

// Blueprint: | `MacAssistantWatchSetupView.swift` | `MacAssistantWatchSetupView`: assistant watch/access controls, readiness reads and actionable Mail/permission checks |

struct MacAssistantWatchSetupView: View {
    var refreshToken: Int = 0

    @Environment(AppModel.self) private var appModel
    @State private var isCheckingMail = false

    private var loadState: MacAssistantWatchSetupLoadState { appModel.engine.macIntegration.watchState }
    private var isLoading: Bool { appModel.engine.macIntegration.isLoadingWatches }

    // Watches and access each use one group card; only failed reads are trouble.
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
                AliveEyebrow("Background watches")
                AliveGroupCard {
                    headerRow
                    if isLoading && loadState.response == nil {
                        ProgressView("Checking access…")
                            .controlSize(.small)
                    } else if let diagnostic = loadState.diagnosticText {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(diagnostic, systemImage: "exclamationmark.triangle")
                                .font(.system(size: 12))
                                .foregroundStyle(NativeAgentShell.trouble)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("mac-assistant-watch.load-error")
                            Text(loadState.response == nil
                                 ? "No watch list is available. Check Mac control and try Refresh again."
                                 : "Showing the last list I had; the refresh did not finish.")
                                .font(.system(size: 12))
                                .foregroundStyle(NativeAgentShell.secondary)
                        }
                    }
                    if let status = loadState.response {
                        ForEach(status.watchTemplates) { template in
                            templateRow(template)
                        }
                    }
                }
            }

            if let status = loadState.response {
                VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
                    AliveEyebrow("What watches can use")
                    AliveGroupCard {
                        ForEach(status.access) { item in
                            accessRow(item)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .task { await load() }
        .onChange(of: refreshToken) { _, _ in
            Task { await load() }
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if let createsJobs = loadState.response?.createsJobs {
                    Text(createsJobs
                         ? "These watches are running. What each run did shows up as it happens."
                         : "These are ready-made watches. None of them runs until you ask me to schedule it.")
                        .font(.system(size: 12))
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let summary = loadState.response?.summary {
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Text(loadStateWord)
                        .accessibilityIdentifier("mac-assistant-watch.load-status")
                    if let attention = loadState.response?.templateAttentionCount, attention > 0 {
                        Text("· \(attention) need\(attention == 1 ? "s" : "") something first")
                            .accessibilityIdentifier("mac-assistant-watch.template-attention")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(loadState.badgeStatus == "failed" ? NativeAgentShell.trouble : NativeAgentShell.secondary)
            }
            Spacer(minLength: 12)
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await load() }
            }
            .disabled(isLoading)
            .accessibilityIdentifier("mac-assistant-watch.refresh")
        }
    }

    /// The load state in plain words.
    private var loadStateWord: String {
        switch loadState {
        case .loading: "Checking…"
        case .stale: "Last known list"
        case .unavailable: "Unavailable"
        case .current(let response):
            response.status == "ready" ? "Everything they need is ready" : "Some need setup"
        }
    }

    private func templateRow(_ template: MacAssistantWatchTemplate) -> some View {
        return statusRow(
            title: template.displayTitle,
            detail: template.displaySummary,
            nextStep: nil,
            status: template.status,
            word: Self.templateWord(template.status)
        )
    }

    private func accessRow(_ item: MacAssistantAccessItem) -> some View {
        let status = item.status
        // A next step that is a place in this app becomes a button to
        // that place, not a sentence pointing at it; Mac Mail gets a real check.
        let action: (label: String, go: () -> Void)? = if item.id == "local_mail" {
            isCheckingMail ? nil : ("Check Mail", { Task { await checkMail() } })
        } else if item.id == "iphone_push" && status != "ready" {
                ("Set up iPhone notifications", {
                    // The iPhone is paired on Connectors' iPhone tab. The route
                    // lands on the page's first tab, synchronously, so the tab is
                    // chosen after it.
                    ApplicationLifetime.shared.request(.sidebar(.connectors))
                    UserDefaults.standard.set("iphone", forKey: ShellRailTab.storageKey(.connectors))
                })
        } else { nil }
        let next = item.id == "local_mail" && ["failed", "needs_permission", "needs_setup"].contains(status)
            ? item.nextStep : action != nil ? nil : item.nextStep.flatMap { $0.isEmpty ? nil : $0 }
        return statusRow(
            title: item.title,
            detail: item.detail,
            nextStep: status == "ready" ? nil : next,
            action: status == "ready" ? nil : action,
            status: status,
            word: isCheckingMail && item.id == "local_mail" ? "Checking…"
                : item.id == "local_mail" && status == "failed" ? "Check failed" : Self.accessWord(item.status)
        )
    }

    /// Reads one Inbox message's metadata through the same Mail read the
    /// watches use. If macOS has not been asked yet, this is what asks.
    private func checkMail() async {
        isCheckingMail = true
        defer { isCheckingMail = false }
        await appModel.engine.macIntegration.checkMail()
    }

    private func statusRow(
        title: String,
        detail: String?,
        nextStep: String?,
        action: (label: String, go: () -> Void)? = nil,
        status: String,
        word: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(NativeAgentShell.text)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let nextStep {
                    Text(nextStep)
                        .font(.system(size: 12))
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let action {
                    Button(action.label, action: action.go)
                        .controlSize(.small)
                        .padding(.top, 3)
                }
            }
            Spacer(minLength: 12)
            // Ready wears the calm colour and a check; orange is only for failures.
            HStack(spacing: 4) {
                if Self.isReady(status) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(word)
                    .multilineTextAlignment(.trailing)
            }
            .font(.system(size: 12))
            .foregroundStyle(
                Self.isTrouble(status) ? NativeAgentShell.trouble
                    : Self.isReady(status) ? NativeAgentShell.calm
                    : NativeAgentShell.secondary
            )
        }
        .accessibilityElement(children: action == nil ? .combine : .contain)
    }

    private func load() async {
        await appModel.engine.macIntegration.refreshWatches()
    }

    // MARK: - Plain words

    private static func isReady(_ status: String) -> Bool {
        ["ready", "ok", "succeeded"].contains(status.lowercased())
    }

    private static func isTrouble(_ status: String) -> Bool {
        ["failed", "error", "unavailable"].contains(status.lowercased())
    }

    private static func accessWord(_ status: String) -> String {
        switch status.lowercased() {
        case "ready", "ok", "succeeded": "Ready"
        case "probe_needed": "Not checked yet"
        case "needs_policy": "Off"
        case "needs_permission": "Needs macOS permission"
        case "needs_setup", "attention": "Needs setup"
        case "failed", "error", "unavailable": "Unavailable"
        default: status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func templateWord(_ status: String) -> String {
        switch status.lowercased() {
        case "needs_policy": "Needs Mac control"
        default: accessWord(status)
        }
    }

}
