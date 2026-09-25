import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ActivityWatch

/// Kept beside the mounted Trust Center control so its disabled state follows
/// exactly the same persisted consent rule as the dispatcher-facing policy.
enum ActivityCapturePresentation {
    static func isAgentAccessControlEnabled(policy: ActivityPolicy) -> Bool {
        policy.captureEnabled
    }
}

/// W8 — the Trust Center surface for the ambient activity watcher.
///
/// The copy here is the feature's actual privacy contract, so it is written to
/// the honest limit rather than the flattering one. Three rules it follows,
/// each of which the build plan's review round forced:
///
///  1. **Never imply titles are sanitised.** `MacScreenViewTextRedaction`
///     catches SHAPED secrets — tokens, keys, one-time codes. It does nothing
///     for "Re: Q3 layoffs — Mail" or "patient-notes.pdf — Preview". Saying
///     "titles are redacted" without saying what redaction does not do would
///     be the single most misleading sentence in the app.
///  2. **Never claim private browsing is excluded.** Private-browsing state is
///     not reliably detectable through AX across Safari/Chrome versions. A
///     browser update would turn that claim into a lie without anyone editing
///     a line of code, so the claim is not made.
///  3. **Say what an action does before it does it.** Adding an app to the
///     exclusion list deletes its existing rows. That is the right behaviour
///     and it is destructive, so it is stated in a confirmation, with the
///     count reported afterwards.
///
/// Alive glass (2026-09-23): an eyebrow over one group card per part, switches
/// instead of checkboxes, and no per-row "applies now" pill — every change on
/// this surface applies at once, said once in the footnote. The master switch
/// says whether recording is on; no pill repeats it.
struct ActivityCapturePermissionsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var controller: ActivityWatchController
    @State private var pendingExclusion: String?
    @State private var showWipeConfirm = false

    init(controller: ActivityWatchController = .shared) {
        _controller = State(initialValue: controller)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            section("Activity capture") {
                masterToggle
                recordedFacts
                if !controller.issues.isEmpty {
                    issuesRow
                }
            }
            section("Window titles") {
                titleControls
            }
            section("My access") {
                modelAccessControl
            }
            section("Excluded apps") {
                exclusionList
            }
            section("Keep history for") {
                retentionAndWipe
            }
            Text("Changes here apply right away.")
                .font(.system(size: 12))
                .foregroundStyle(NativeAgentShell.secondary)
        }
        .accessibilityElement(children: .contain)
        .alert("Exclude this app and delete what was recorded?", isPresented: exclusionAlertBinding) {
            Button("Exclude and delete", role: .destructive) {
                if let bundleID = pendingExclusion {
                    Task { await controller.addExclusion(bundleID: bundleID) }
                }
                pendingExclusion = nil
            }
            Button("Cancel", role: .cancel) { pendingExclusion = nil }
        } message: {
            // The destructive half is stated FIRST, because it is the half a
            // user would not expect from a control labelled "exclude".
            Text("""
            Everything already recorded for \(pendingExclusion.map(appName) ?? "this app") is deleted now and \
            for good: not hidden, deleted, including from the database's recovery log. Answers \
            about past days will no longer include it.

            From now on I skip this app before reading anything about it: no window title, \
            no app name, no row at all.
            """)
        }
        .alert("Delete all recorded activity?", isPresented: $showWipeConfirm) {
            Button("Delete everything", role: .destructive) {
                Task { await controller.wipeAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
            Everything recorded is deleted for good. Your settings here are kept, so if \
            recording is on it keeps going. Turn it off first if you want it to stop too.
            """)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
            AliveEyebrow(title)
            AliveGroupCard { content() }
        }
    }

    /// A switch row: the words on the left, the switch on the right.
    private func switchRow(
        _ title: String,
        detail: String? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(NativeAgentShell.text)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .hazeTinted()
        }
    }

    private func issueColor(_ severity: ActivityCaptureIssue.Severity) -> Color {
        switch severity {
        case .notice: NativeAgentShell.secondary
        case .warning, .critical: NativeAgentShell.trouble
        }
    }

    // MARK: - Master toggle

    private var masterToggle: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Record which apps you use")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(NativeAgentShell.text)
            Spacer(minLength: 12)
            Toggle(
                "Record which apps you use",
                isOn: Binding(
                    get: { controller.policy.captureEnabled },
                    set: { controller.setCaptureEnabled($0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .hazeTinted()
        }
        .help("Off by default. Nothing is recorded until you turn this on, and nothing was recorded before you did.")
    }

    // WHAT IS RECORDED / WHAT IS NOT. Two lists, both concrete. A single
    // paragraph of reassurance would be easier to write and worth nothing to
    // someone deciding whether to trust this.
    private var recordedFacts: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "Recorded: the app in front, and how long it was in front.",
                systemImage: "checkmark.circle"
            )
            Label(
                "Recorded only if you choose window titles below: the window title, with obvious secrets (tokens, keys, one-time codes) taken out.",
                systemImage: "questionmark.circle"
            )
            Label(
                "Never recorded: what you type, what is in any field or window, or screenshots. Nothing while the Mac is locked or asleep.",
                systemImage: "xmark.circle"
            )
            Label(
                "The record never leaves this Mac: no iCloud, backup, export or iPhone sync. Whether I can use it in answers is set under My access below.",
                // Plain lock: inside a circle at 12pt the lock read as a dot.
                systemImage: "lock"
            )
        }
        .font(.system(size: 12))
        .foregroundStyle(NativeAgentShell.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var issuesRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Activity capture notices", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(issueColor(controller.primaryIssue?.severity ?? .notice))
            ForEach(controller.presentationIssues) { issue in
                HStack(alignment: .top, spacing: 6) {
                    Label(issue.severity.title, systemImage: issue.severity.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(issueColor(issue.severity))
                    Text(issue.occurredAt, style: .time)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(NativeAgentShell.secondary)
                    Text(issue.message)
                        .font(.system(size: 12))
                        .foregroundStyle(NativeAgentShell.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier(
                    issue.id == controller.primaryIssue?.id
                        ? "activity.capture.last-error"
                        : "activity.capture.issue"
                )
            }
        }
    }

    // Full Mac admits `activity_query` on trusted chats whatever the saved
    // switch says (ActivityQueryService.run, fullMacAdmitted), so under Full
    // Mac there is no switch: a switch reading off would be false.
    @ViewBuilder
    private var modelAccessControl: some View {
        let title = "Let me answer from activity history"
        let detail = "With Full Mac I can use your recorded activity in trusted chats. In other modes a switch here decides, and it starts off. When I answer from it, the answer goes to the chat's AI provider; the database and full history stay on this Mac. Recording itself is the switch at the top."
        if appModel.trustPolicy.map(AppModel.fullMacGrantIsActive) ?? false {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(NativeAgentShell.text)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Text("On with Full Mac")
                    .font(.system(size: 12))
                    .foregroundStyle(NativeAgentShell.secondary)
                    .help("Full Mac lets me answer from your recorded activity in trusted chats. In narrower modes this is a switch. Recording must still be on.")
            }
        } else {
            switchRow(
                title,
                detail: detail,
                isOn: Binding(
                    get: { controller.policy.allowModelAccess },
                    set: { controller.setModelAccessEnabled($0) }
                )
            )
            .disabled(!ActivityCapturePresentation.isAgentAccessControlEnabled(policy: controller.policy))
        }
    }

    // MARK: - Title controls

    /// The three saved title fields as the one choice they really are. Read
    /// the way `ActivityPolicy.allowsTitleCapture` reads them, so the picker
    /// shows what capture actually does; rendering writes nothing.
    enum TitleCapture: Hashable, CaseIterable {
        case appNamesOnly, windowTitles, windowAndBrowserTitles

        init(policy: ActivityPolicy) {
            if policy.appNameOnlyMode || !policy.captureTitles {
                self = .appNamesOnly
            } else {
                self = policy.browserTitlesEnabled ? .windowAndBrowserTitles : .windowTitles
            }
        }

        func applied(to policy: ActivityPolicy) -> ActivityPolicy {
            var next = policy
            next.appNameOnlyMode = self == .appNamesOnly
            next.captureTitles = self != .appNamesOnly
            next.browserTitlesEnabled = self == .windowAndBrowserTitles
            return next
        }

        var label: String {
            switch self {
            case .appNamesOnly: "App names only"
            case .windowTitles: "Window titles"
            case .windowAndBrowserTitles: "Window and browser titles"
            }
        }
    }

    @ViewBuilder
    private var titleControls: some View {
        let choice = TitleCapture(policy: controller.policy)
        Picker("Window titles", selection: Binding(
            get: { choice },
            // One write through the controller's one save path, so the three
            // fields never land half-changed.
            set: { controller.apply($0.applied(to: controller.policy)) }
        )) {
            ForEach(TitleCapture.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .hazeTinted(.segments)
        .labelsHidden()

        VStack(alignment: .leading, spacing: 8) {
            switch choice {
            case .appNamesOnly:
                Text("No titles are recorded, only which app is in front and for how long.")
            case .windowTitles:
                titleLimit
                Text("Browser window titles are not recorded.")
            case .windowAndBrowserTitles:
                titleLimit
                // NO PRIVATE-BROWSING CLAIM. Stated as a limitation, not buried.
                Text("""
                A browser title is usually the page title, so the title of each page you visit is \
                recorded. Private and incognito browsing is NOT excluded: I cannot reliably tell a \
                private window from a normal one (macOS does not say so dependably, and a browser \
                update could change it).
                """)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(NativeAgentShell.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // THE HONEST LIMIT. This paragraph is the reason the whole feature is
    // defensible, and it must not be softened into "titles are redacted for
    // your privacy".
    private var titleLimit: some View {
        Text("""
        I take things that look like secrets (API keys, tokens, one-time codes) out of titles, \
        and nothing else. A title like "Re: Q3 layoffs — Mail", "patient-notes.pdf — Preview", \
        or a client's name in a file path is recorded as it is. If that is not OK for an app, \
        exclude the app below.
        """)
    }

    // MARK: - Exclusions

    @ViewBuilder
    private var exclusionList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("""
            I skip an excluded app before reading anything about it: no title, no app name, \
            no row. Password managers, Keychain Access, Health, Messages and several finance \
            apps are excluded from the start. Adding an app here also deletes what I already \
            recorded for it.
            """)
            .font(.system(size: 12))
            .foregroundStyle(NativeAgentShell.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Menu("Exclude an app", systemImage: "minus.circle") {
                ForEach(runningAppChoices, id: \.bundleID) { app in
                    Button(app.name) { pendingExclusion = app.bundleID }
                }
                Divider()
                Button("Other app…") { chooseOtherApp() }
            }
            .fixedSize()

            if let purged = controller.lastPurgedRowCount {
                Label(
                    purged == 0
                        ? "No recorded rows needed deleting."
                        : "Deleted \(purged) recorded row\(purged == 1 ? "" : "s").",
                    systemImage: "trash"
                )
                .font(.system(size: 12))
                .foregroundStyle(NativeAgentShell.secondary)
            }
        }

        DisclosureGroup("View excluded apps (\(controller.removableExclusions.count))") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(controller.removableExclusions, id: \.self) { bundleID in
                    HStack {
                        Text(appName(bundleID))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(bundleID)
                        Spacer()
                        Button("Remove", systemImage: "xmark.circle") {
                            controller.removeExclusion(bundleID: bundleID)
                        }
                        .buttonStyle(.borderless)
                    }
                    .textSelection(.enabled)
                    .accessibilityElement(children: .contain)
                }
            }
            .padding(.top, 8)
        }
        .font(.system(size: 13))

        // The non-overridable exclusions are shown as a fact, not as a
        // control, because they cannot be removed and a disabled row that
        // looks removable is a lie about who is in charge.
        Text("I never record my own windows or the lock screen. Those two can't be turned off.")
            .font(.system(size: 12))
            .foregroundStyle(NativeAgentShell.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Retention + wipe

    @ViewBuilder
    private var retentionAndWipe: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Keep history for", selection: Binding(
                get: { controller.policy.retentionDays },
                set: { controller.setRetentionDays($0) }
            )) {
                Text("7 days").tag(7)
                Text("14 days").tag(14)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
            }
            .pickerStyle(.segmented)
            .hazeTinted(.segments)
            .labelsHidden()
            Text("Anything older is deleted on its own. Shortening this deletes the extra at the next cleanup.")
                .font(.system(size: 12))
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
            Button("Delete all recorded activity", systemImage: "trash", role: .destructive) {
                showWipeConfirm = true
            }
            .foregroundStyle(.red)
            Spacer()
        }
    }

    /// Regular apps running now, not already excluded, by name.
    private var runningAppChoices: [(name: String, bundleID: String)] {
        let excluded = controller.policy.excludedBundleIDs
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (name: String, bundleID: String)? in
                guard let id = app.bundleIdentifier, !excluded.contains(id),
                      seen.insert(id).inserted else { return nil }
                return (app.localizedName ?? id, id)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @MainActor
    private func chooseOtherApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose an app to exclude"
        panel.prompt = "Choose App"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier else { return }
        pendingExclusion = id
    }

    private func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return url.deletingPathExtension().lastPathComponent
    }

    private var exclusionAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingExclusion != nil },
            set: { if !$0 { pendingExclusion = nil } }
        )
    }
}
