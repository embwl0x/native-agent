import SwiftUI
import Observation

/// Appearance, manual refresh, and completed setup/probe actions can overlap.
/// Only the newest requested inventory may replace the mounted readiness state.
@MainActor @Observable
final class MacAssistantWatchSetupReadState {
    private(set) var loadState: MacAssistantWatchSetupLoadState = .loading
    private(set) var isLoading = false
    @ObservationIgnored private var generation: UInt64 = 0

    @discardableResult
    func reload(read: @MainActor () async throws -> MacAssistantStatusResponse) async -> Bool {
        generation &+= 1
        let request = generation
        isLoading = true
        defer {
            if request == generation { isLoading = false }
        }
        do {
            let status = try await read()
            guard !Task.isCancelled, request == generation else { return false }
            loadState = .current(status)
            return true
        } catch {
            guard !Task.isCancelled, request == generation else { return false }
            loadState = loadState.afterFailure(
                "Couldn’t refresh background watches: \(error.localizedDescription)"
            )
            return false
        }
    }
}

struct MacAssistantWatchSetupView: View {
    typealias StatusReader = @MainActor () async throws -> MacAssistantStatusResponse

    var refreshToken: Int
    private let statusReader: StatusReader?
    private let loadsOnAppear: Bool

    @Environment(AppModel.self) private var appModel
    @State private var readState = MacAssistantWatchSetupReadState()
    /// The last Check Mail result. The status read has no Mail source of its
    /// own (it can only say "not checked yet"), so the check's real outcome
    /// is what the Mac Mail row shows once it has run.
    @State private var mailCheck: (status: String, word: String, next: String?)?
    @State private var isCheckingMail = false

    private var loadState: MacAssistantWatchSetupLoadState { readState.loadState }
    private var isLoading: Bool { readState.isLoading }

    init(
        refreshToken: Int = 0,
        statusReader: StatusReader? = nil,
        loadsOnAppear: Bool = true
    ) {
        self.refreshToken = refreshToken
        self.statusReader = statusReader
        self.loadsOnAppear = loadsOnAppear
    }

    // Alive glass (2026-09-23): the watches and what they can use are two
    // eyebrows over one group card each. Status words are quiet; only a read
    // that failed is trouble. "Needs proof" is a state, not trouble: the
    // templates are inert until scheduled, and the connector proof this build
    // uses never verifies on its own.
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
        let plain = Self.plainTemplate[template.id]
        let when = template.scheduleLabel.map { $0.prefix(1).lowercased() + $0.dropFirst() }
        let sentence = plain.map { $0.sentence.replacingOccurrences(of: "{when}", with: when ?? "on a schedule") }
            ?? [template.scheduleLabel, template.summary].compactMap { $0 }.joined(separator: " · ")
        return statusRow(
            title: plain?.title ?? template.title,
            detail: sentence,
            nextStep: nil,
            status: template.status,
            word: Self.templateWord(template.status)
        )
    }

    private func accessRow(_ item: MacAssistantAccessItem) -> some View {
        let plain = Self.plainAccess[item.id]
        let title = plain?.title ?? item.title
        let check = item.id == "local_mail" ? mailCheck : nil
        let status = check?.status ?? item.status
        let notConnected = item.nextStep == "Configure connector proof in the NativeAgent app"
        // The macOS prompt note matters only until access is ready.
        var detail = plain?.detail ?? item.detail
        if status != "ready", let note = Self.promptNote[item.id] {
            detail = (detail ?? "") + note
        }
        // The two next steps that are a place in this app become a button to
        // that place, not a sentence pointing at it; Mac Mail gets a real check.
        let action: (label: String, go: () -> Void)? = if item.id == "local_mail" {
            isCheckingMail ? nil : ("Check Mail", { Task { await checkMail() } })
        } else {
            switch item.nextStep {
            case "Configure connector proof in the NativeAgent app":
                ("Connect \(title)", { NativeAgentAppCoordinator.shared.request(.sidebar(.connectors)) })
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
        let next = check.map(\.next)
            ?? (action != nil ? nil : item.nextStep.flatMap { $0.isEmpty ? nil : (Self.plainNextStep[$0] ?? $0) })
        return statusRow(
            title: title,
            detail: detail,
            nextStep: status == "ready" ? nil : next,
            action: status == "ready" ? nil : action,
            status: status,
            word: isCheckingMail && item.id == "local_mail" ? "Checking…"
                : check?.word ?? (notConnected ? "Not connected" : Self.accessWord(item.status))
        )
    }

    /// Reads one Inbox message's metadata through the same Mail read the
    /// watches use. If macOS has not been asked yet, this is what asks.
    private func checkMail() async {
        isCheckingMail = true
        defer { isCheckingMail = false }
        do {
            guard case .object(let out) = try await MacAppleScriptBridge.mailListRecent(input: ["limit": .int(1)]) else {
                mailCheck = ("failed", "Check failed", "Mail gave no answer I could read.")
                return
            }
            let text = { (key: String) -> String? in
                if case .string(let s)? = out[key], !s.isEmpty { return s }
                return nil
            }
            switch text("status") {
            case "completed":
                mailCheck = ("ready", "Ready", nil)
            case "denied":
                mailCheck = ("needs_permission", "Needs macOS permission",
                             "Allow NativeAgent to control Mail in System Settings → Privacy & Security → Automation.")
            default:
                if text("reason") == "not_configured" {
                    mailCheck = ("needs_setup", "Needs setup", text("fix"))
                } else {
                    mailCheck = ("failed", "Check failed", text("error") ?? text("reason").map { "Mail said: \($0.replacingOccurrences(of: "_", with: " "))." })
                }
            }
        } catch {
            mailCheck = ("failed", "Check failed", error.localizedDescription)
        }
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
        await readState.reload {
            if let statusReader {
                return try await statusReader()
            } else {
                return try await appModel.getMacAssistantStatus()
            }
        }
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
        case "needs_proof": "Not verified"
        case "needs_permission": "Needs macOS permission"
        case "needs_setup", "attention": "Needs setup"
        case "failed", "error", "unavailable": "Unavailable"
        default: status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func templateWord(_ status: String) -> String {
        switch status.lowercased() {
        case "needs_policy": "Needs Mac control"
        case "needs_proof": "Needs a verified account"
        default: accessWord(status)
        }
    }

    /// The watches the status client offers, by id, in first person. `{when}`
    /// is the template's own schedule label, so a changed schedule reads true.
    private static let plainTemplate: [String: (title: String, sentence: String)] = [
        "gmail_unread_digest": ("Gmail digest", "I check your unread Gmail {when} and note what I find for your digest."),
        "google_calendar_window_watch": ("Google Calendar", "I check your upcoming Google Calendar events {when}."),
        "local_mail_watch": ("Mac Mail", "I check Mail for unread messages {when} (read only)."),
        "local_calendar_watch": ("Mac Calendar", "I check Calendar for the next day {when} (read only)."),
        "local_reminders_watch": ("Mac Reminders", "I check Reminders for due and overdue items {when} (read only)."),
        "morning_brief_watch": ("Morning brief", "I turn your email and calendar into a brief card {when}."),
    ]

    private static let plainAccess: [String: (title: String, detail: String)] = [
        "mac_control": ("Mac control", "Lets me run shortcuts, post notifications, read files and script apps on this Mac."),
        "mac_notifications": ("Mac notifications", "I post notifications on this Mac."),
        "iphone_push": ("iPhone notifications", "I send what a watch found to your iPhone."),
        "gmail": ("Gmail", "I read Gmail only once the connection is verified, not just because you are signed in."),
        "google_calendar": ("Google Calendar", "I read events only after a fresh check that the account works."),
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
        "Open NativeAgent > Mac Integration and click Grant beside Calendar to open the macOS permission prompt.": "Click Grant beside Calendar on the Mac integration tab.",
        "Open NativeAgent > Mac Integration and click Grant beside Reminders to open the macOS permission prompt.": "Click Grant beside Reminders on the Mac integration tab.",
        "Enable Calendar access for NativeAgent in System Settings > Privacy & Security.": "Allow Calendar for NativeAgent in System Settings → Privacy & Security.",
        "Enable Reminders access for NativeAgent in System Settings > Privacy & Security.": "Allow Reminders for NativeAgent in System Settings → Privacy & Security.",
    ]
}
