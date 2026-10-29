import SwiftUI
import NativeAgentShared
import Combine
// Blueprint: | `MacToolsView.swift` | Mac controls use PhoneMacControlAction and the shared Trust snapshot; receipts live in MacActionReceipts |

// MARK: - MacToolsView

struct MacToolsView: View {
    @EnvironmentObject private var pairingStore: PairingStore
    private let sync = iCloudSyncEngine.shared
    private var macPolicy: MacControlPolicyWireSnapshot? { sync.trustPolicy?.macControlPolicy }
    @State private var hasLoadedPolicy = false
    @State private var notifTitle = ""
    @State private var notifMessage = ""
    @State private var isSendingNotif = false
    @State private var notifResult: MacNotificationSendPresentation.Feedback?
    @State private var volume: Double = MacVolumeControlPresentation.defaultTargetFraction
    /// No target shows until one is picked; this is not a live volume gauge.
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

    private func allowed(_ privilege: PhoneMacControlAction) -> Bool {
        paired && MacToolsPrivilegePresentation.isAllowed(privilege, policy: macPolicy)
    }

    /// Unpaired, the page's one reason says why; no per-card Trust hint.
    private func footer(_ privilege: PhoneMacControlAction, _ text: String?) -> String? {
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

        // ── Notification ───────────────────────────────────────────
        AliveSection(
            "Send a notification",
            footer: footer(.notification, notifResult?.text)
        ) {
            field("Title", text: $notifTitle).aliveRow()
                .aliveUnavailable(!allowed(.notification))
            AliveDivider()
            HStack(spacing: 12) {
                field("Message", text: $notifMessage)
                Button {
                    Task { await sendNotification() }
                } label: {
                    if isSendingNotif { ProgressView().controlSize(.small) } else { Text("Send") }
                }
                .aliveSecondaryButton()
                .disabled(notifMessage.isEmpty || isSendingNotif || !allowed(.notification))
                .accessibilityLabel(notifResult.map { "Send. Notification status: \($0.text)" } ?? "Send")
            }
            .aliveRow()
            .aliveUnavailable(!allowed(.notification))
        }

        // ── The Mac itself ─────────────────────────────────────────
        AliveSection(
            "The Mac",
            footer: footer(.volume, MacVolumeControlPresentation.currentVolumeDisclosure)
        ) {
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
            .aliveUnavailable(!allowed(.volume))
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
    private func lockedText(_ privilege: PhoneMacControlAction) -> String {
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
        case .volume(let percent):
            await setVolume(percentOverride: percent, retrying: action.id)
        case .spotlight(let query):
            await runSpotlight(queryOverride: query, retrying: action.id)
        }
    }

    // MARK: - Logic

    private func refresh() async {
        await loadPolicy()
    }

    // Every Mac action goes through iCloudSyncEngine.

    private func loadPolicy() async {
        #if DEBUG
        if MobileDesignSamples.screen != nil {
            loadDesignSample()
            return
        }
        #endif
        _ = await sync.refreshTrustSnapshot()
        hasLoadedPolicy = true
    }

    #if DEBUG
    /// `-designScreen mac-tools`: an open policy and two receipts, never sent anywhere.
    private func loadDesignSample() {
        sync.trustPolicy = TrustPolicy(macControlPolicy: MacControlPolicyWireSnapshot(enabled: true, systemControlAllowed: true, approvalRequiredFor: [], remoteFromIosAllowed: true))
        hasLoadedPolicy = true
        guard remoteActionLedger.actions.isEmpty else { return }
        let volume = remoteActionLedger.start(.volume(40), title: "Set volume", subtitle: "40%")
        remoteActionLedger.update(volume, state: .failed, detail: "The Mac didn’t answer in time.")
        let search = remoteActionLedger.start(.spotlight("Meeting notes"), title: "Spotlight search", subtitle: "Meeting notes")
        remoteActionLedger.update(search, state: .ranOnMac, detail: "2 result(s)")
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
            updateRemoteAction(actionID, state: .ranOnMac, detail: "Ran on Mac through iCloud")
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
}
