import SwiftUI
import MacIntegration
import EngineRuntime

// Blueprint: | `MacAssistantWatchSetupView.swift` | `MacAssistantWatchSetupView`: assistant watch/access controls, readiness reads and actionable Mail/permission checks |

struct MacAssistantWatchSetupView: View {
    var refreshToken: Int
    private let loadsOnAppear: Bool

    @Environment(AppModel.self) private var appModel
    @State private var isCheckingMail = false

    private var loadState: MacAssistantWatchSetupLoadState { appModel.engine.macIntegration.watchState }
    private var isLoading: Bool { appModel.engine.macIntegration.isLoadingWatches }

    init(
        refreshToken: Int = 0,
        loadsOnAppear: Bool = true
    ) {
        self.refreshToken = refreshToken
        self.loadsOnAppear = loadsOnAppear
    }

    // Alive glass (2026-09-23): the watches and what they can use are two
    // eyebrows over one group card each. Status words are quiet; only a read
    // that failed is trouble.
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
        .task {
            guard loadsOnAppear else { return }
            await load()
        }
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
        let plain = Self.plainAccess[item.id]
        let title = plain?.title ?? item.title
        let status = item.status
        // The macOS prompt note matters only until access is ready.
        var detail = plain?.detail ?? item.detail
        if status != "ready", let note = Self.promptNote[item.id] {
            detail = detail + note
        }
        // A next step that is a place in this app becomes a button to
        // that place, not a sentence pointing at it; Mac Mail gets a real check.
        let action: (label: String, go: () -> Void)? = if item.id == "local_mail" {
            isCheckingMail ? nil : ("Check Mail", { Task { await checkMail() } })
        } else {
            switch item.nextStep {
            case "Configure mobile push in NativeAgent settings":
                ("Set up iPhone notifications", {
                    // The iPhone is paired on Connectors' iPhone tab. The route
                    // lands on the page's first tab, synchronously, so the tab is
                    // chosen after it.
                    NativeAgentAppCoordinator.shared.request(.sidebar(.connectors))
                    UserDefaults.standard.set("iphone", forKey: ShellRailTab.storageKey(.connectors))
                })
            default: nil
            }
        }
        let next = item.id == "local_mail" && ["failed", "needs_permission", "needs_setup"].contains(status)
            ? item.nextStep : action != nil ? nil : item.nextStep.flatMap { $0.isEmpty ? nil : (Self.plainNextStep[$0] ?? $0) }
        return statusRow(
            title: title,
            detail: detail,
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

    private static let plainAccess: [String: (title: String, detail: String)] = [
        "mac_control": ("Mac control", "Lets me run shortcuts, post notifications, read files and script apps on this Mac."),
        "mac_notifications": ("Mac notifications", "I post notifications on this Mac."),
        "iphone_push": ("iPhone notifications", "I send what a watch found to your iPhone."),
        "local_mail": ("Mac Mail", "I read your Mail inbox (read only)."),
        "local_calendar": ("Mac Calendar", "I read Calendar (read only)."),
        "local_reminders": ("Mac Reminders", "I read Reminders (read only)."),
    ]

    /// Said only while the source is not ready yet.
    private static let promptNote: [String: String] = [
        "local_mail": " The first check shows the macOS permission prompt.",
        "local_calendar": " The first check shows the macOS permission prompt.",
        "local_reminders": " The first check shows the macOS permission prompt.",
    ]

    /// The status client's known next steps, said plainly. Anything else is
    /// shown as it comes.
    private static let plainNextStep: [String: String] = [
        "Enable Mac Control in Trust Center.": "Turn on Mac control above.",
        "Enable Mac Control notifications and send a test notification.": "Turn on Notifications under Advanced Mac control, then send a test notification.",
        "Run mac.mail_list_recent once from the app to prove Mail.app access.": "Use Check Mail so macOS can ask for access.",
        "Run mac.calendar_list_upcoming once from the app to prove Calendar access.": "Use Check Calendar and Reminders above so macOS can ask for access.",
        "Run mac.reminders_list_due_today once from the app to prove Reminders access.": "Use Check Calendar and Reminders above so macOS can ask for access.",
        "Open NativeAgent > Mac Integration and click Grant beside Calendar to open the macOS permission prompt.": "Click Grant beside Calendar on Trust's Mac tab.",
        "Open NativeAgent > Mac Integration and click Grant beside Reminders to open the macOS permission prompt.": "Click Grant beside Reminders on Trust's Mac tab.",
        "Enable Calendar access for NativeAgent in System Settings > Privacy & Security.": "Allow Calendar for NativeAgent in System Settings → Privacy & Security.",
        "Enable Reminders access for NativeAgent in System Settings > Privacy & Security.": "Allow Reminders for NativeAgent in System Settings → Privacy & Security.",
    ]
}
