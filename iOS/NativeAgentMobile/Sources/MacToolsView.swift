// PATCH-2026-05-07: mac-control-ui-1 iOS Mac Tools — remote Mac Control from iPhone/iPad
import SwiftUI

// MARK: - MacToolsView

struct MacToolsView: View {
    @State private var macPolicy: TrustMacControlPolicy?
    @State private var hasLoadedPolicy = false
    @State private var manualShortcutName = ""
    @State private var notifTitle = ""
    @State private var notifMessage = ""
    @State private var isSendingNotif = false
    @State private var notifResult: MacNotificationSendPresentation.Feedback?
    @State private var volume: Double = MacVolumeControlPresentation.defaultTargetFraction
    @State private var isSettingVolume = false
    @State private var spotlightQuery = ""
    @State private var spotlightOutcome: MacToolsSpotlightPresentation.Outcome?
    @State private var showsAllSpotlightResults = false
    @State private var isSearching = false
    @State private var actionStatus: String?
    @StateObject private var remoteActionLedger = RemoteActionLedger.shared

    private var remoteActions: [RemoteActionCard] {
        remoteActionLedger.actions
    }

    private var iosOk: Bool {
        MacToolsPolicyGatePresentation.state(for: macPolicy) == .enabled
    }

    private var volumeTargetPercent: Int {
        MacVolumeControlPresentation.targetPercent(for: volume)
    }

    var body: some View {
        Group {
            if !hasLoadedPolicy {
                ProgressView("Checking Mac Control...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !iosOk {
                disabledEmptyState
            } else {
                enabledContent
            }
        }
        .task { await refresh() }
        .mobileReadingScreen()
        .navigationTitle("Mac Tools")
        .macSyncErrorBanner()
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
                MacStatusChip().frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
            }
        .refreshable { await refresh() }
    }

    // MARK: - Disabled empty state
    // PATCH-2026-05-07: polish-MacToolsView gradient icon + Material card for disabled state

    private var disabledEmptyState: some View {
        VStack(spacing: 20) {
            MobileReadingEmptyState(
                title: "Mac Tools Unavailable",
                systemImage: "macbook.and.iphone",
                kind: .unavailable,
                description: MacToolsPolicyGatePresentation.disabledDescription(for: macPolicy)
            )
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Enabled content

    private var enabledContent: some View {
        List {
            // ── Status header ──────────────────────────────────────────
            Section {
                MobileReadingSurface {
                    MobileAdaptiveRow(spacing: 12) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Mac Tools Active")
                                .font(.headline)
                            Text("Mac Control enabled · iOS remote allowed")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } header: {
                Label("Mac Tools", systemImage: "macbook.and.iphone")
                    .font(.headline)
            }

            Section {
                if remoteActions.isEmpty {
                    Text("Remote Mac actions will appear here with live status, approval handoff, retry, and completion receipts.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(remoteActions.prefix(8)) { action in
                        RemoteActionCardView(action: action) {
                            Task { await retry(action) }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            } header: {
                Label("Remote Actions", systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline)
            } footer: {
                Text("Remote action receipts remain available while this app session is open.")
                    .font(.callout)
            }

            // ── Shortcuts ──────────────────────────────────────────────
            Section {
                if !MacToolsPrivilegePresentation.isAllowed(.shortcuts, policy: macPolicy) {
                    lockedPolicyRow(MacToolsPrivilegePresentation.disabledDescription(for: .shortcuts))
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        MobileAdaptiveRow(spacing: 8) {
                            Image(systemName: "square.stack.3d.up")
                                .foregroundStyle(.secondary)
                            TextField("Shortcut name, exactly as on the Mac", text: $manualShortcutName)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                                .submitLabel(.go)
                                .onSubmit {
                                    let name = manualShortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !name.isEmpty else { return }
                                    Task { await runShortcut(name) }
                                }
                            Button {
                                let name = manualShortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !name.isEmpty else { return }
                                Task { await runShortcut(name) }
                            } label: {
                                Label("Run", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                    .foregroundStyle(NativeAgentMobileTheme.Colors.onAccent)
                            .disabled(manualShortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        Text("Runs the named Shortcut on your Mac. Find the exact name in the Shortcuts app.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Label("Shortcuts", systemImage: "square.stack.3d.up")
                    .font(.headline)
            }

            // ── Quick Actions ──────────────────────────────────────────
            Section {
                // Send notification
                VStack(alignment: .leading, spacing: 8) {
                    Text("Send Notification")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("Title", text: $notifTitle)
                        .textFieldStyle(.roundedBorder)
                    TextField("Message", text: $notifMessage)
                        .textFieldStyle(.roundedBorder)
                    if !MacToolsPrivilegePresentation.isAllowed(.notifications, policy: macPolicy) {
                        lockedPolicyRow(MacToolsPrivilegePresentation.disabledDescription(for: .notifications))
                    }
                    MobileAdaptiveRow {
                        Button {
                            Task { await sendNotification() }
                        } label: {
                            if isSendingNotif {
                                ProgressView()
                            } else {
                                Label("Send", systemImage: "bell")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    .foregroundStyle(NativeAgentMobileTheme.Colors.onAccent)
                        .disabled(
                            notifMessage.isEmpty || isSendingNotif
                                || !MacToolsPrivilegePresentation.isAllowed(.notifications, policy: macPolicy)
                        )
                        if let r = notifResult {
                            Label(r.text, systemImage: r.systemImage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Notification status: \(r.text)")
                        }
                    }
                }
                .padding(.vertical, 4)

                // Lock screen
                Button {
                    Task { await quickAction("lock_screen") }
                } label: {
                    Label("Lock Screen", systemImage: "lock.display")
                }
                .disabled(!MacToolsPrivilegePresentation.isAllowed(.systemControl, policy: macPolicy))

                // Sleep display
                Button {
                    Task { await quickAction("sleep_display") }
                } label: {
                    Label("Sleep Display", systemImage: "display")
                }
                .disabled(!MacToolsPrivilegePresentation.isAllowed(.systemControl, policy: macPolicy))

                // A2: reason for the Lock Screen / Sleep Display pair — both gate
                // on systemControlAllowed and were previously opacity-only.
                if !MacToolsPrivilegePresentation.isAllowed(.systemControl, policy: macPolicy) {
                    lockedPolicyRow(MacToolsPrivilegePresentation.disabledDescription(for: .systemControl))
                }

                // Volume slider
                VStack(alignment: .leading, spacing: 6) {
                    Text("Choose a volume target")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    MobileAdaptiveRow {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $volume, in: 0...1, step: 0.05)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                    Text("Target: \(volumeTargetPercent)%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(MacVolumeControlPresentation.currentVolumeDisclosure)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await setVolume() }
                    } label: {
                        if isSettingVolume {
                            ProgressView()
                        } else {
                            Text("Set target \(volumeTargetPercent)%")
                        }
                    }
                    .buttonStyle(.bordered)
                .tint(.secondary)
                    .disabled(
                        isSettingVolume
                            || !MacToolsPrivilegePresentation.isAllowed(.systemControl, policy: macPolicy)
                    )
                    if !MacToolsPrivilegePresentation.isAllowed(.systemControl, policy: macPolicy) {
                        lockedPolicyRow(MacToolsPrivilegePresentation.disabledDescription(for: .systemControl))
                    }
                }
                .padding(.vertical, 4)

                // Spotlight search
                VStack(alignment: .leading, spacing: 6) {
                    Text("Spotlight Search")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    MobileAdaptiveRow {
                        TextField("Search…", text: $spotlightQuery)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.search)
                            .onSubmit { Task { await runSpotlight() } }
                        Button {
                            Task { await runSpotlight() }
                        } label: {
                            if isSearching { ProgressView() } else { Image(systemName: "magnifyingglass") }
                        }
                        .buttonStyle(.bordered)
                .tint(.secondary)
                        .disabled(
                            spotlightQuery.isEmpty || isSearching
                                || !MacToolsPrivilegePresentation.isAllowed(.spotlight, policy: macPolicy)
                        )
                    }
                    if !MacToolsPrivilegePresentation.isAllowed(.spotlight, policy: macPolicy) {
                        lockedPolicyRow(MacToolsPrivilegePresentation.disabledDescription(for: .spotlight))
                    }
                    if let spotlightOutcome {
                        spotlightResultPresentation(spotlightOutcome)
                    }
                }
                .padding(.vertical, 4)

                if let status = actionStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            } header: {
                Label("Quick Actions", systemImage: "bolt")
                    .font(.headline)
            }

        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func spotlightResultPresentation(_ outcome: MacToolsSpotlightPresentation.Outcome) -> some View {
        switch outcome {
        case .emptyResponse:
            Label(outcome.statusText, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .noResults:
            Label(outcome.statusText, systemImage: "magnifyingglass")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .results:
            VStack(alignment: .leading, spacing: 5) {
                ForEach(outcome.visibleRows(showingAll: showsAllSpotlightResults), id: \.self) { result in
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(showsAllSpotlightResults ? nil : 1)
                        .textSelection(.enabled)
                }
                if let truncationText = outcome.truncationText(showingAll: showsAllSpotlightResults) {
                    Text(truncationText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button(showsAllSpotlightResults ? "Show fewer Spotlight results" : "Show all Spotlight results") {
                        showsAllSpotlightResults.toggle()
                    }
                    .font(.callout)
                }
            }
        }
    }

    // A2: reusable inline reason for a policy-gated control. Appends the
    // actionable Trust-tab hint so a disabled control isn't just dimmed — it
    // says why it's off and where to turn it on. Matches the app's existing
    // "Mac app's Trust tab" copy (see disabledEmptyState).
    private func lockedPolicyRow(_ text: String) -> some View {
        Label("\(text) Enable in the Mac app's Trust tab.", systemImage: "lock.fill")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @discardableResult
    private func startRemoteAction(_ kind: RemoteActionKind, title: String, subtitle: String) -> UUID {
        withAnimation(AppMotion.snappy) {
            remoteActionLedger.start(kind, title: title, subtitle: subtitle)
        }
    }

    private func updateRemoteAction(_ id: UUID, state: RemoteActionState, detail: String) {
        withAnimation(AppMotion.snappy) {
            remoteActionLedger.update(id, state: state, detail: detail)
        }
    }

    private func retry(_ action: RemoteActionCard) async {
        switch action.kind {
        case .notify(let title, let message):
            await sendNotification(titleOverride: title, messageOverride: message, retrying: action.id)
        case .system(let command):
            await quickAction(command, retrying: action.id)
        case .volume(let percent):
            await setVolume(percentOverride: percent, retrying: action.id)
        case .spotlight(let query):
            await runSpotlight(queryOverride: query, retrying: action.id)
        case .shortcut(let name):
            await runShortcut(name, retrying: action.id)
        }
    }

    // MARK: - Logic

    private func refresh() async {
        await loadPolicy()
    }

    // PATCH-2026-06-02: iCloud is the only iOS transport. Retired LAN/HTTP
    // helpers and their URLSession fallbacks have been removed;
    // every Mac action below goes through iCloudSyncEngine.

    private func loadPolicy() async {
        let snapshotLoaded = await iCloudSyncEngine.shared.refreshTrustSnapshot()
        macPolicy = MacToolsPolicyGatePresentation.policyForGate(
            snapshotLoaded: snapshotLoaded,
            refreshedPolicy: iCloudSyncEngine.shared.trustPolicy?.macControlPolicy
        )
        hasLoadedPolicy = true
    }

    private func sendNotification(titleOverride: String? = nil, messageOverride: String? = nil, retrying cardID: UUID? = nil) async {
        isSendingNotif = true
        notifResult = nil
        let title = titleOverride ?? (notifTitle.isEmpty ? "NativeAgent" : notifTitle)
        let message = messageOverride ?? notifMessage
        let actionID = cardID ?? startRemoteAction(.notify(title: title, message: message), title: "Send notification", subtitle: title)
        updateRemoteAction(
            actionID,
            state: .running,
            detail: RemoteActionRetryPresentation.dispatchDetail(
                for: .notify(title: title, message: message),
                isRetry: cardID != nil
            )
        )
        do {
            _ = try await iCloudSyncEngine.shared.macNotify(title: title, message: message)
            notifResult = .sent
            updateRemoteAction(actionID, state: .ranOnMac, detail: "Ran on Mac through iCloud")
            notifMessage = ""
            notifTitle = ""
        } catch {
            notifResult = .failed(error.localizedDescription)
            updateRemoteAction(actionID, state: RemoteActionState.forError(error), detail: error.localizedDescription)
        }
        isSendingNotif = false
    }

    private func quickAction(_ action: String, retrying cardID: UUID? = nil) async {
        guard let quickAction = MacSystemQuickAction(rawValue: action) else {
            let completion = MacSystemQuickActionExecution.unsupported(named: action)
            actionStatus = completion.status
            if let cardID {
                updateRemoteAction(cardID, state: completion.state, detail: completion.detail)
            }
            return
        }
        actionStatus = "Running \(action)…"
        let actionID = cardID ?? startRemoteAction(.system(action), title: action.replacingOccurrences(of: "_", with: " ").capitalized, subtitle: "System action")
        updateRemoteAction(
            actionID,
            state: .running,
            detail: RemoteActionRetryPresentation.dispatchDetail(
                for: .system(action),
                isRetry: cardID != nil
            )
        )
        let completion = await MacSystemQuickActionExecution.execute(quickAction) { action in
            switch action {
            case .lockScreen:
                _ = try await iCloudSyncEngine.shared.macLockScreen()
            case .sleepDisplay:
                _ = try await iCloudSyncEngine.shared.macSleepDisplay()
            }
        }
        actionStatus = completion.status
        updateRemoteAction(actionID, state: completion.state, detail: completion.detail)
    }

    private func setVolume(percentOverride: Int? = nil, retrying cardID: UUID? = nil) async {
        isSettingVolume = true
        actionStatus = nil
        let percent = percentOverride ?? volumeTargetPercent
        let actionID = cardID ?? startRemoteAction(.volume(percent), title: "Set volume", subtitle: "\(percent)%")
        updateRemoteAction(
            actionID,
            state: .running,
            detail: RemoteActionRetryPresentation.dispatchDetail(
                for: .volume(percent),
                isRetry: cardID != nil
            )
        )
        do {
            _ = try await iCloudSyncEngine.shared.macSetVolume(percent: percent)
            actionStatus = MacVolumeControlPresentation.acknowledgement(percent: percent)
            updateRemoteAction(actionID, state: .ranOnMac, detail: "Mac accepted the request; current volume is not read back.")
        } catch {
            actionStatus = error.localizedDescription
            updateRemoteAction(actionID, state: RemoteActionState.forError(error), detail: error.localizedDescription)
        }
        isSettingVolume = false
    }

    private func runSpotlight(queryOverride: String? = nil, retrying cardID: UUID? = nil) async {
        let query = queryOverride ?? spotlightQuery
        guard !query.isEmpty else { return }
        isSearching = true
        spotlightOutcome = nil
        showsAllSpotlightResults = false
        let actionID = cardID ?? startRemoteAction(.spotlight(query), title: "Spotlight search", subtitle: query)
        updateRemoteAction(
            actionID,
            state: .running,
            detail: RemoteActionRetryPresentation.dispatchDetail(
                for: .spotlight(query),
                isRetry: cardID != nil
            )
        )
        do {
            let raw = try await iCloudSyncEngine.shared.macSpotlight(query: query)
            let outcome = MacToolsSpotlightPresentation.outcome(from: raw)
            spotlightOutcome = outcome
            actionStatus = outcome.statusText

            switch outcome {
            case .emptyResponse:
                updateRemoteAction(actionID, state: .failed, detail: outcome.statusText)
            case .noResults, .results:
                updateRemoteAction(actionID, state: .ranOnMac, detail: "\(outcome.resultCount) result(s)")
            }
        } catch {
            actionStatus = error.localizedDescription
            updateRemoteAction(actionID, state: RemoteActionState.forError(error), detail: error.localizedDescription)
        }
        isSearching = false
    }

    private func runShortcut(_ name: String, retrying cardID: UUID? = nil) async {
        actionStatus = "Running shortcut \"\(name)\"…"
        let actionID = cardID ?? startRemoteAction(.shortcut(name), title: "Run shortcut", subtitle: name)
        updateRemoteAction(
            actionID,
            state: .running,
            detail: RemoteActionRetryPresentation.dispatchDetail(
                for: .shortcut(name),
                isRetry: cardID != nil
            )
        )
        do {
            _ = try await iCloudSyncEngine.shared.macShortcut(name: name)
            actionStatus = "Shortcut ran."
            updateRemoteAction(actionID, state: .ranOnMac, detail: "Ran on Mac through iCloud")
        } catch {
            let failure = MacShortcutRunnerPresentation.failure(for: error, shortcutName: name)
            actionStatus = failure.status
            updateRemoteAction(actionID, state: RemoteActionState.forError(error), detail: failure.detail)
        }
    }
}

// MARK: - Remote Action Cards

enum RemoteActionState: String, Equatable {
    case waiting = "waiting"
    case running = "running"
    case waitingApproval = "waiting approval"
    case ranOnMac = "ran on Mac"
    case failed = "failed"

    static func forError(_ error: Error) -> Self {
        if case SyncError.approvalRequired = error {
            return .waitingApproval
        }
        return .failed
    }

    var offersRetry: Bool { self == .failed }

    var color: Color {
        switch self {
        case .waiting, .running: return .orange
        case .waitingApproval: return .purple
        case .ranOnMac: return .green
        case .failed: return .red
        }
    }

    var icon: String {
        switch self {
        case .waiting: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .waitingApproval: return "checkmark.shield"
        case .ranOnMac: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }
}

/// A remote action's recovery is determined by its typed terminal state, not
/// by matching an error sentence.  Pending approval and ordinary failure have
/// distinct next steps and must never collapse into the same Retry affordance.
enum RemoteActionCardRecoveryPresentation {
    enum Control: Equatable {
        case none
        case reviewApproval
        case retry
    }

    static func control(for state: RemoteActionState) -> Control {
        switch state {
        case .waitingApproval: .reviewApproval
        case .failed: .retry
        case .waiting, .running, .ranOnMac: .none
        }
    }
}

enum RemoteActionKind: Equatable {
    case notify(title: String, message: String)
    case system(String)
    case volume(Int)
    case spotlight(String)
    case shortcut(String)
}

enum RemoteActionRetryPresentation {
    static func dispatchDetail(for action: RemoteActionKind, isRetry: Bool) -> String {
        guard isRetry else {
            if case .spotlight = action { return "Searching Mac" }
            return "Sending to Mac"
        }

        switch action {
        case .notify(let title, let message):
            return "Retrying original notification \"\(title)\": \"\(message)\" — not the current composer draft."
        case .system(let command):
            return "Retrying original system action: \(command.replacingOccurrences(of: "_", with: " "))."
        case .volume(let percent):
            return "Retrying original volume target: \(percent)% — not the current slider value."
        case .spotlight(let query):
            return "Retrying original Spotlight search \"\(query)\" — not the current search field."
        case .shortcut(let name):
            return "Retrying original shortcut \"\(name)\" — not the current shortcut field."
        }
    }
}

struct RemoteActionCard: Identifiable, Equatable {
    let id: UUID
    var kind: RemoteActionKind
    var title: String
    var subtitle: String
    var state: RemoteActionState
    var detail: String
    var createdAt: Date
    var updatedAt: Date

    init(kind: RemoteActionKind, title: String, subtitle: String, state: RemoteActionState, detail: String) {
        self.id = UUID()
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.state = state
        self.detail = detail
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

/// App-session receipt ownership for Mac Tools. A waiting approval is the
/// user's only direct breadcrumb from an interrupted remote action to
/// Activity, so ordinary receipt trimming may never evict it.
@MainActor
final class RemoteActionLedger: ObservableObject {
    static let shared = RemoteActionLedger()

    @Published private(set) var actions: [RemoteActionCard] = []
    private let maximumOrdinaryActions: Int

    init(maximumOrdinaryActions: Int = 12) {
        self.maximumOrdinaryActions = max(0, maximumOrdinaryActions)
    }

    @discardableResult
    func start(_ kind: RemoteActionKind, title: String, subtitle: String) -> UUID {
        let card = RemoteActionCard(
            kind: kind,
            title: title,
            subtitle: subtitle,
            state: .waiting,
            detail: "Queued for Mac"
        )
        actions.insert(card, at: 0)
        trimOrdinaryActions()
        return card.id
    }

    func update(_ id: UUID, state: RemoteActionState, detail: String) {
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return }
        actions[index].state = state
        actions[index].detail = detail
        actions[index].updatedAt = Date()
        trimOrdinaryActions()
    }

    private func trimOrdinaryActions() {
        let approvalWaits = actions.filter { $0.state == .waitingApproval }
        let ordinary = actions.filter { $0.state != .waitingApproval }
        actions = approvalWaits + Array(ordinary.prefix(maximumOrdinaryActions))
    }
}

private struct RemoteActionCardView: View {
    let action: RemoteActionCard
    let onRetry: () -> Void

    var body: some View {
        MobileReadingSurface {
            VStack(alignment: .leading, spacing: 8) {
                MobileAdaptiveRow(alignment: .top, spacing: 12) {
                    Image(systemName: action.state.icon)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(action.title)
                            .font(.headline)
                        Text(action.subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Text(action.state.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(NativeAgentMobileTheme.Colors.quietFill, in: Capsule())
                }
                Text(action.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                MobileAdaptiveRow {
                    Text(action.updatedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if action.state == .waitingApproval,
                       RemoteActionCardRecoveryPresentation.control(for: action.state) == .reviewApproval {
                        Text("Approval status is local to this session; review it in Activity.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Review Approval", systemImage: "checkmark.shield") {
                            NotificationCenter.default.post(
                                name: .nativeagentOpenActivity,
                                object: nil,
                                userInfo: ["screen": "approvals"]
                            )
                        }
                        .buttonStyle(.borderedProminent)
                    .foregroundStyle(NativeAgentMobileTheme.Colors.onAccent)
                    } else if action.state == .failed,
                              RemoteActionCardRecoveryPresentation.control(for: action.state) == .retry {
                        Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
                            .buttonStyle(.bordered)
                .tint(.secondary)
                    }
                }
            }
        }
    }
}
