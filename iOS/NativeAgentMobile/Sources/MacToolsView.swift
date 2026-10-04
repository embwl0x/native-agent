// PATCH-2026-05-07: mac-control-ui-1 iOS Mac Tools — remote Mac Control from iPhone/iPad
import SwiftUI
import Combine
import NativeAgentShared

// MARK: - MacToolsView

struct MacToolsView: View {
    @EnvironmentObject private var pairingStore: PairingStore
    @State private var macPolicy: TrustMacControlPolicy?
    @State private var hasLoadedPolicy = false
    @State private var manualShortcutName = ""
    @State private var notifTitle = ""
    @State private var notifMessage = ""
    @State private var isSendingNotif = false
    @State private var notifResult: MacNotificationSendPresentation.Feedback?
    @State private var volume: Double = MacVolumeControlPresentation.defaultTargetFraction
    /// No level shows until one is picked: the Mac never says its volume.
    @State private var volumePicked = false
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

    private var paired: Bool { pairingStore.isPaired }

    private func allowed(_ privilege: MacToolsPrivilege) -> Bool {
        paired && MacToolsPrivilegePresentation.isAllowed(privilege, policy: macPolicy)
    }

    /// Unpaired, the page's one reason says why; no per-card Trust hint.
    private func footer(_ privilege: MacToolsPrivilege, _ text: String?) -> String? {
        !paired ? nil : allowed(privilege) ? text : lockedText(privilege)
    }

    var body: some View {
        AlivePage(title: "Mac Tools", line: "Things I can do on your Mac from here.") {
            if !paired {
                AliveUnpairedReason()
                enabledContent
            } else if !hasLoadedPolicy {
                ProgressView("Checking Mac Control…")
                    .foregroundStyle(AlivePalette.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else if !iosOk {
                disabledEmptyState
            } else {
                enabledContent
            }
        }
        .task { await refresh() }
        .macSyncErrorBanner()
        .refreshable { await refresh() }
    }

    // MARK: - Disabled empty state

    private var disabledEmptyState: some View {
        AliveCalmState(
            title: "Mac Tools are off",
            line: MacToolsPolicyGatePresentation.disabledDescription(for: macPolicy),
            actionTitle: "Check again",
            action: { Task { await refresh() } }
        )
    }

    // MARK: - Enabled content

    @ViewBuilder
    private var enabledContent: some View {
        if let status = actionStatus {
            AliveFootnote(status, systemImage: "arrow.turn.down.right")
        }

        // ── Shortcuts ──────────────────────────────────────────────
        AliveSection(
            "Run a shortcut",
            footer: footer(.shortcuts, "Use the name exactly as it appears in Shortcuts on the Mac.")
        ) {
            HStack(spacing: 12) {
                field("Shortcut name", text: $manualShortcutName)
                    .submitLabel(.go)
                    .onSubmit { submitShortcut() }
                Button("Run") { submitShortcut() }
                    .alivePrimaryButton()
                    .disabled(manualShortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || !allowed(.shortcuts))
            }
            .aliveRow()
            .aliveUnavailable(!allowed(.shortcuts))
        }

        // ── Notification ───────────────────────────────────────────
        AliveSection(
            "Send a notification",
            footer: footer(.notifications, notifResult?.text)
        ) {
            field("Title", text: $notifTitle).aliveRow()
                .aliveUnavailable(!allowed(.notifications))
            AliveDivider()
            HStack(spacing: 12) {
                field("Message", text: $notifMessage)
                Button {
                    Task { await sendNotification() }
                } label: {
                    if isSendingNotif { ProgressView().controlSize(.small) } else { Text("Send") }
                }
                .aliveSecondaryButton()
                .disabled(notifMessage.isEmpty || isSendingNotif || !allowed(.notifications))
                .accessibilityLabel(notifResult.map { "Send. Notification status: \($0.text)" } ?? "Send")
            }
            .aliveRow()
            .aliveUnavailable(!allowed(.notifications))
        }

        // ── The Mac itself ─────────────────────────────────────────
        AliveSection(
            "The Mac",
            footer: footer(.systemControl, MacVolumeControlPresentation.currentVolumeDisclosure)
        ) {
            actionRow("Lock screen") { Task { await quickAction("lock_screen") } }
            AliveDivider()
            actionRow("Sleep display") { Task { await quickAction("sleep_display") } }
            AliveDivider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Volume").font(.body).foregroundStyle(AlivePalette.text)
                    Spacer()
                    Text(volumePicked ? "\(volumeTargetPercent)%" : "\u{2014}")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(AlivePalette.secondary)
                        .accessibilityLabel(volumePicked ? "Target \(volumeTargetPercent)%" : "No level picked")
                }
                HStack(spacing: 12) {
                    Slider(value: $volume, in: 0...1, step: 0.05)
                        .onChange(of: volume) { volumePicked = true }
                        .hazeTinted()
                        .accessibilityLabel("Volume target")
                    Button {
                        Task { await setVolume() }
                    } label: {
                        if isSettingVolume { ProgressView().controlSize(.small) } else { Text("Set") }
                    }
                    .aliveSecondaryButton()
                    .disabled(!volumePicked)
                    .accessibilityLabel("Set target \(volumeTargetPercent)%")
                }
            }
            .aliveRow()
            .disabled(isSettingVolume)
            .aliveUnavailable(!allowed(.systemControl))
        }

        // ── Spotlight ──────────────────────────────────────────────
        AliveSection("Search the Mac", footer: footer(.spotlight, nil)) {
            HStack(spacing: 12) {
                field("Spotlight", text: $spotlightQuery)
                    .submitLabel(.search)
                    .onSubmit { Task { await runSpotlight() } }
                Button {
                    Task { await runSpotlight() }
                } label: {
                    if isSearching { ProgressView().controlSize(.small) } else { Image(systemName: "magnifyingglass") }
                }
                .aliveSecondaryButton()
                .disabled(spotlightQuery.isEmpty || isSearching)
                .accessibilityLabel("Search")
            }
            .aliveRow()
            .aliveUnavailable(!allowed(.spotlight))
            if let spotlightOutcome {
                AliveDivider()
                spotlightResultPresentation(spotlightOutcome)
                    .aliveRow()
            }
        }

        // ── Receipts ───────────────────────────────────────────────
        if !remoteActions.isEmpty {
            AliveSection("Recent on the Mac", footer: "Kept while this app stays open.") {
                ForEach(Array(remoteActions.enumerated()), id: \.element.id) { index, action in
                    if index > 0 { AliveDivider() }
                    RemoteActionCardView(action: action) {
                        Task { await retry(action) }
                    }
                }
            }
        }
    }

    /// An input inside a card: no border of its own, the card is the field.
    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text, prompt: Text(prompt).foregroundStyle(AlivePalette.secondary))
            .font(.body)
            .foregroundStyle(AlivePalette.text)
            .autocorrectionDisabled()
            .frame(minHeight: 36)
    }

    /// A tappable row that does one thing on the Mac.
    private func actionRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body)
                .foregroundStyle(AlivePalette.text)
                .aliveRow()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .aliveUnavailable(!allowed(.systemControl))
    }

    private func submitShortcut() {
        let name = manualShortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task { await runShortcut(name) }
    }

    @ViewBuilder
    private func spotlightResultPresentation(_ outcome: MacToolsSpotlightPresentation.Outcome) -> some View {
        switch outcome {
        case .emptyResponse, .invalidResponse, .noResults:
            Text(outcome.statusText)
                .font(.subheadline)
                .foregroundStyle(AlivePalette.secondary)
        case .results:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(outcome.visibleRows(showingAll: showsAllSpotlightResults), id: \.self) { result in
                    Text(result)
                        .font(.subheadline)
                        .foregroundStyle(AlivePalette.text)
                        .lineLimit(showsAllSpotlightResults ? nil : 1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let truncationText = outcome.truncationText(showingAll: showsAllSpotlightResults) {
                    Text(truncationText)
                        .font(.footnote)
                        .foregroundStyle(AlivePalette.secondary)
                    Button(showsAllSpotlightResults ? "Show fewer Spotlight results" : "Show all Spotlight results") {
                        showsAllSpotlightResults.toggle()
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AlivePalette.text)
                }
            }
        }
    }

    // A2: reusable inline reason for a policy-gated control. Appends the
    // actionable Trust-tab hint so a disabled control isn't just dimmed — it
    // says why it's off and where to turn it on. Matches the app's existing
    // "Mac app's Trust tab" copy (see disabledEmptyState).
    private func lockedText(_ privilege: MacToolsPrivilege) -> String {
        "\(MacToolsPrivilegePresentation.disabledDescription(for: privilege)) Enable in the Mac app's Trust tab."
    }

    @discardableResult
    private func startRemoteAction(_ kind: RemoteActionKind, title: String, subtitle: String) -> UUID {
        withAnimation(AppMotion.snappy) {
            remoteActionLedger.start(kind, title: title, subtitle: subtitle)
        }
    }

    private func updateRemoteAction(_ id: UUID, state: RemoteActionState, detail: String, approvalID: String? = nil) {
        withAnimation(AppMotion.snappy) {
            remoteActionLedger.update(id, state: state, detail: detail, approvalID: approvalID)
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
        #if DEBUG
        if MobileDesignSamples.screen != nil {
            loadDesignSample()
            return
        }
        #endif
        let snapshotLoaded = await iCloudSyncEngine.shared.refreshTrustSnapshot()
        macPolicy = MacToolsPolicyGatePresentation.policyForGate(
            snapshotLoaded: snapshotLoaded,
            refreshedPolicy: iCloudSyncEngine.shared.trustPolicy?.macControlPolicy
        )
        hasLoadedPolicy = true
    }

    #if DEBUG
    /// `-designScreen mac-tools`: an open policy and two receipts, never sent anywhere.
    private func loadDesignSample() {
        macPolicy = TrustMacControlPolicy(enabled: true, systemControlAllowed: true, remoteFromIosAllowed: true)
        hasLoadedPolicy = true
        guard remoteActionLedger.actions.isEmpty else { return }
        let volume = remoteActionLedger.start(.volume(40), title: "Set volume", subtitle: "40%")
        remoteActionLedger.update(volume, state: .failed, detail: "The Mac didn’t answer in time.")
        let shortcut = remoteActionLedger.start(.shortcut("Morning focus"), title: "Run shortcut", subtitle: "Morning focus")
        remoteActionLedger.update(shortcut, state: .ranOnMac, detail: "Ran on Mac through iCloud")
    }
    #endif

    private func sendNotification(titleOverride: String? = nil, messageOverride: String? = nil, retrying cardID: UUID? = nil) async {
        isSendingNotif = true
        notifResult = nil
        let submittedTitle = notifTitle
        let submittedMessage = notifMessage
        let title = titleOverride ?? (notifTitle.isEmpty ? iCloudSyncEngine.shared.agentDisplayName : notifTitle)
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
            if cardID == nil, titleOverride == nil, messageOverride == nil,
               notifTitle == submittedTitle, notifMessage == submittedMessage {
                notifMessage = ""
                notifTitle = ""
            }
        } catch {
            notifResult = .failed(error.localizedDescription)
            updateRemoteAction(actionID, state: RemoteActionState.forError(error), detail: error.localizedDescription,
                               approvalID: (error as? SyncError)?.approvalID)
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
        actionStatus = "Running \(action.replacingOccurrences(of: "_", with: " "))…"
        let actionID = cardID ?? startRemoteAction(.system(action), title: AliveWords.humanized(action), subtitle: "System action")
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
        updateRemoteAction(actionID, state: completion.state, detail: completion.detail, approvalID: completion.approvalID)
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
            updateRemoteAction(actionID, state: RemoteActionState.forError(error), detail: error.localizedDescription,
                               approvalID: (error as? SyncError)?.approvalID)
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
            case .emptyResponse, .invalidResponse:
                updateRemoteAction(actionID, state: .failed, detail: outcome.statusText)
            case .noResults, .results:
                updateRemoteAction(actionID, state: .ranOnMac, detail: "\(outcome.resultCount) result(s)")
            }
        } catch {
            actionStatus = error.localizedDescription
            updateRemoteAction(actionID, state: RemoteActionState.forError(error), detail: error.localizedDescription,
                               approvalID: (error as? SyncError)?.approvalID)
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
            updateRemoteAction(actionID, state: RemoteActionState.forError(error), detail: failure.detail,
                               approvalID: (error as? SyncError)?.approvalID)
        }
    }
}

// MARK: - Remote Action Cards

enum RemoteActionState: String, Equatable {
    case waiting = "waiting"
    case running = "running"
    case waitingApproval = "waiting approval"
    case approvalResolved = "approval resolved"
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
        case .approvalResolved: return .secondary
        case .ranOnMac: return .green
        case .failed: return .red
        }
    }

    var icon: String {
        switch self {
        case .waiting: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .waitingApproval: return "checkmark.shield"
        case .approvalResolved: return "checkmark.shield"
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
        case .waiting, .running, .ranOnMac, .approvalResolved: .none
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
    var approvalID: String?

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
    private var approvalsObserver: AnyCancellable?

    init(maximumOrdinaryActions: Int = 12) {
        self.maximumOrdinaryActions = max(0, maximumOrdinaryActions)
        approvalsObserver = iCloudSyncEngine.shared.$approvals.sink { [weak self] approvals in
            self?.reconcileApprovals(approvals)
        }
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

    func update(_ id: UUID, state: RemoteActionState, detail: String, approvalID: String? = nil) {
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return }
        actions[index].state = state
        actions[index].detail = detail
        actions[index].updatedAt = Date()
        actions[index].approvalID = approvalID?.isEmpty == false ? approvalID : nil
        reconcileApprovals(iCloudSyncEngine.shared.approvals)
    }

    private func reconcileApprovals(_ approvals: [ApprovalRequest]) {
        for index in actions.indices where actions[index].state == .waitingApproval {
            guard let id = actions[index].approvalID,
                  let approval = approvals.first(where: { $0.id == id }),
                  ["resolved", "denied", "canceled", "orphaned"]
                    .contains(approval.status.lowercased()) else { continue }
            actions[index].state = .approvalResolved
            actions[index].detail = "Approval \(approval.decision ?? approval.status). Check Activity for the action outcome."
            actions[index].updatedAt = Date()
        }
        trimOrdinaryActions()
    }

    private func trimOrdinaryActions() {
        var ordinaryCount = 0
        actions = actions.sorted { $0.updatedAt > $1.updatedAt }.filter { action in
            if action.state == .waitingApproval, action.approvalID != nil { return true }
            ordinaryCount += 1
            return ordinaryCount <= maximumOrdinaryActions
        }
    }
}


/// One receipt as a row: what ran, its state and age in secondary text, and
/// the next step only when there is one.
private struct RemoteActionCardView: View {
    let action: RemoteActionCard
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(action.title)
                        .font(.body)
                        .foregroundStyle(AlivePalette.text)
                    (Text("\(action.subtitle) · \(action.state.rawValue) · ")
                        + Text(action.updatedAt, format: .relative(presentation: .named)))
                        .font(.subheadline)
                        .foregroundStyle(AlivePalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if action.state == .failed,
                   RemoteActionCardRecoveryPresentation.control(for: action.state) == .retry {
                    Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
                        .labelStyle(.titleOnly)
                        .aliveSecondaryButton()
                }
            }
            Text(action.detail)
                .font(.footnote)
                .foregroundStyle(AlivePalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if action.state == .waitingApproval,
               RemoteActionCardRecoveryPresentation.control(for: action.state) == .reviewApproval {
                Text("Review this approval in Activity.")
                    .font(.footnote)
                    .foregroundStyle(AlivePalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Review Approval", systemImage: "checkmark.shield") {
                    NotificationCenter.default.post(
                        name: .nativeagentOpenActivity,
                        object: nil,
                        userInfo: ["screen": "approvals"]
                    )
                }
                .labelStyle(.titleOnly)
                .alivePrimaryButton()
            }
        }
        .aliveRow()
    }
}
