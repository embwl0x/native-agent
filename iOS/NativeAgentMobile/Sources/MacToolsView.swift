// PATCH-2026-05-07: mac-control-ui-1 iOS Mac Tools — remote Mac Control from iPhone/iPad
import SwiftUI

// MARK: - MacToolsView

struct MacToolsView: View {
    @State private var macPolicy: TrustMacControlPolicy?
    @State private var hasLoadedPolicy = false
    @State private var policyLoadError: String?
    @State private var manualShortcutName = ""
    @State private var notifTitle = ""
    @State private var notifMessage = ""
    @State private var isSendingNotif = false
    @State private var notifResult: String?
    @State private var volume: Double = 0.5
    @State private var isSettingVolume = false
    @State private var spotlightQuery = ""
    @State private var spotlightResults: [String] = []
    @State private var isSearching = false
    @State private var actionStatus: String?
    @State private var remoteActions: [RemoteActionCard] = []

    private var masterEnabled: Bool { macPolicy?.enabled == true }
    private var remoteAllowed: Bool { macPolicy?.remoteFromIosAllowed == true }
    private var iosOk: Bool { masterEnabled && remoteAllowed }

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
        .navigationTitle("Mac Tools")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
    }

    // MARK: - Disabled empty state
    // PATCH-2026-05-07: polish-MacToolsView gradient icon + Material card for disabled state

    private var disabledEmptyState: some View {
        VStack(spacing: 20) {
            AppEmptyState(
                title: "Mac Tools Unavailable",
                systemImage: "macbook.and.iphone",
                description: policyLoadError ?? (!masterEnabled
                    ? "Enable Agent Access → Full Mac or turn on Mac Control in the Mac app's Trust tab."
                    : "Enable iOS remote control in the Mac app's Trust tab under Mac Control.")
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
                GlassCard(tint: .green, cornerRadius: 14) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mac Tools Active")
                                .font(AppFont.section)
                            Text("Mac Control enabled · iOS remote allowed")
                                .font(AppFont.label)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } header: {
                Label("Mac Tools", systemImage: "macbook.and.iphone")
                    .font(AppFont.section)
            }

            Section {
                if remoteActions.isEmpty {
                    Text("Remote Mac actions will appear here with live status, approval handoff, retry, and completion receipts.")
                        .font(AppFont.label)
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
                    .font(AppFont.section)
            }

            // ── Shortcuts ──────────────────────────────────────────────
            Section {
                if macPolicy?.shortcutsAllowed != true {
                    lockedPolicyRow("Shortcuts are disabled by Mac Control policy.")
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "square.stack.3d.up")
                                .foregroundStyle(NativeAgentPalette.agentAccent)
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
                            .disabled(manualShortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        Text("Runs the named Shortcut on your Mac. Find the exact name in the Shortcuts app.")
                            .font(AppFont.label)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Label("Shortcuts", systemImage: "square.stack.3d.up")
                    .font(AppFont.section)
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
                    HStack {
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
                        .disabled(notifMessage.isEmpty || isSendingNotif || macPolicy?.notificationsAllowed != true)
                        if let r = notifResult {
                            Text(r).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if macPolicy?.notificationsAllowed != true {
                        lockedPolicyRow("Notifications are disabled by Mac Control policy.")
                    }
                }
                .padding(.vertical, 4)

                // Lock screen
                Button {
                    Task { await quickAction("lock_screen") }
                } label: {
                    Label("Lock Screen", systemImage: "lock.display")
                }
                .disabled(macPolicy?.systemControlAllowed != true)

                // Sleep display
                Button {
                    Task { await quickAction("sleep_display") }
                } label: {
                    Label("Sleep Display", systemImage: "display")
                }
                .disabled(macPolicy?.systemControlAllowed != true)

                // A2: reason for the Lock Screen / Sleep Display pair — both gate
                // on systemControlAllowed and were previously opacity-only.
                if macPolicy?.systemControlAllowed != true {
                    lockedPolicyRow("System controls are disabled by Mac Control policy.")
                }

                // Volume slider
                VStack(alignment: .leading, spacing: 6) {
                    Text("Set Volume")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $volume, in: 0...1, step: 0.05)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await setVolume() }
                    } label: {
                        if isSettingVolume {
                            ProgressView()
                        } else {
                            Text("Set \(Int(volume * 100))%")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSettingVolume || macPolicy?.systemControlAllowed != true)
                    if macPolicy?.systemControlAllowed != true {
                        lockedPolicyRow("System controls are disabled by Mac Control policy.")
                    }
                }
                .padding(.vertical, 4)

                // Spotlight search
                VStack(alignment: .leading, spacing: 6) {
                    Text("Spotlight Search")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack {
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
                        .disabled(spotlightQuery.isEmpty || isSearching || macPolicy?.spotlightAllowed != true)
                    }
                    if macPolicy?.spotlightAllowed != true {
                        lockedPolicyRow("Spotlight is disabled by Mac Control policy.")
                    }
                    if !spotlightResults.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(spotlightResults.prefix(8), id: \.self) { result in
                                Text(result)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
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
                    .font(AppFont.section)
            }

        }
        .listStyle(.insetGrouped)
    }

    // A2: reusable inline reason for a policy-gated control. Appends the
    // actionable Trust-tab hint so a disabled control isn't just dimmed — it
    // says why it's off and where to turn it on. Matches the app's existing
    // "Mac app's Trust tab" copy (see disabledEmptyState).
    private func lockedPolicyRow(_ text: String) -> some View {
        Label("\(text) Enable in the Mac app's Trust tab.", systemImage: "lock.fill")
            .font(AppFont.label)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @discardableResult
    private func startRemoteAction(_ kind: RemoteActionKind, title: String, subtitle: String) -> UUID {
        let card = RemoteActionCard(kind: kind, title: title, subtitle: subtitle, state: .waiting, detail: "Queued for Mac")
        withAnimation(AppMotion.snappy) {
            remoteActions.insert(card, at: 0)
            remoteActions = Array(remoteActions.prefix(12))
        }
        return card.id
    }

    private func updateRemoteAction(_ id: UUID, state: RemoteActionState, detail: String) {
        withAnimation(AppMotion.snappy) {
            guard let idx = remoteActions.firstIndex(where: { $0.id == id }) else { return }
            remoteActions[idx].state = state
            remoteActions[idx].detail = detail
            remoteActions[idx].updatedAt = Date()
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
        policyLoadError = nil
        await iCloudSyncEngine.shared.refreshTrustSnapshot()
        if let snap = iCloudSyncEngine.shared.trustPolicy,
           let mcPolicy = snap.macControlPolicy {
            macPolicy = mcPolicy
        } else {
            policyLoadError = "No Mac Control policy snapshot yet."
        }
        hasLoadedPolicy = true
    }

    private func sendNotification(titleOverride: String? = nil, messageOverride: String? = nil, retrying cardID: UUID? = nil) async {
        isSendingNotif = true
        notifResult = nil
        let title = titleOverride ?? (notifTitle.isEmpty ? "NativeAgent" : notifTitle)
        let message = messageOverride ?? notifMessage
        let actionID = cardID ?? startRemoteAction(.notify(title: title, message: message), title: "Send notification", subtitle: title)
        updateRemoteAction(actionID, state: .running, detail: "Sending to Mac")
        do {
            _ = try await iCloudSyncEngine.shared.macNotify(title: title, message: message)
            notifResult = "Sent."
            updateRemoteAction(actionID, state: .ranOnMac, detail: "Ran on Mac through iCloud")
            notifMessage = ""
            notifTitle = ""
        } catch {
            notifResult = error.localizedDescription
            updateRemoteAction(actionID, state: error.localizedDescription.lowercased().contains("approval") ? .waitingApproval : .failed, detail: error.localizedDescription)
        }
        isSendingNotif = false
    }

    private func quickAction(_ action: String, retrying cardID: UUID? = nil) async {
        actionStatus = "Running \(action)…"
        let actionID = cardID ?? startRemoteAction(.system(action), title: action.replacingOccurrences(of: "_", with: " ").capitalized, subtitle: "System action")
        updateRemoteAction(actionID, state: .running, detail: "Sending to Mac")
        do {
            if action == "lock_screen" {
                _ = try await iCloudSyncEngine.shared.macLockScreen()
            } else if action == "sleep_display" {
                _ = try await iCloudSyncEngine.shared.macSleepDisplay()
            }
            actionStatus = "Done."
            updateRemoteAction(actionID, state: .ranOnMac, detail: "Ran on Mac through iCloud")
        } catch {
            actionStatus = error.localizedDescription
            updateRemoteAction(actionID, state: error.localizedDescription.lowercased().contains("approval") ? .waitingApproval : .failed, detail: error.localizedDescription)
        }
    }

    private func setVolume(percentOverride: Int? = nil, retrying cardID: UUID? = nil) async {
        isSettingVolume = true
        actionStatus = nil
        let percent = percentOverride ?? Int(volume * 100)
        let actionID = cardID ?? startRemoteAction(.volume(percent), title: "Set volume", subtitle: "\(percent)%")
        updateRemoteAction(actionID, state: .running, detail: "Sending to Mac")
        do {
            _ = try await iCloudSyncEngine.shared.macSetVolume(percent: percent)
            actionStatus = "Volume set."
            updateRemoteAction(actionID, state: .ranOnMac, detail: "Ran on Mac through iCloud")
        } catch {
            actionStatus = error.localizedDescription
            updateRemoteAction(actionID, state: error.localizedDescription.lowercased().contains("approval") ? .waitingApproval : .failed, detail: error.localizedDescription)
        }
        isSettingVolume = false
    }

    private func runSpotlight(queryOverride: String? = nil, retrying cardID: UUID? = nil) async {
        let query = queryOverride ?? spotlightQuery
        guard !query.isEmpty else { return }
        isSearching = true
        spotlightResults = []
        let actionID = cardID ?? startRemoteAction(.spotlight(query), title: "Spotlight search", subtitle: query)
        updateRemoteAction(actionID, state: .running, detail: "Searching Mac")
        do {
            let raw = try await iCloudSyncEngine.shared.macSpotlight(query: query)
            let lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            spotlightResults = lines.isEmpty ? [] : lines
            actionStatus = "\(spotlightResults.count) Spotlight result(s)."
            updateRemoteAction(actionID, state: .ranOnMac, detail: "\(spotlightResults.count) result(s)")
        } catch {
            actionStatus = error.localizedDescription
            updateRemoteAction(actionID, state: error.localizedDescription.lowercased().contains("approval") ? .waitingApproval : .failed, detail: error.localizedDescription)
        }
        isSearching = false
    }

    private func runShortcut(_ name: String, retrying cardID: UUID? = nil) async {
        actionStatus = "Running shortcut \"\(name)\"…"
        let actionID = cardID ?? startRemoteAction(.shortcut(name), title: "Run shortcut", subtitle: name)
        updateRemoteAction(actionID, state: .running, detail: "Sending to Mac")
        do {
            _ = try await iCloudSyncEngine.shared.macShortcut(name: name)
            actionStatus = "Shortcut ran."
            updateRemoteAction(actionID, state: .ranOnMac, detail: "Ran on Mac through iCloud")
        } catch {
            actionStatus = error.localizedDescription
            updateRemoteAction(actionID, state: error.localizedDescription.lowercased().contains("approval") ? .waitingApproval : .failed, detail: error.localizedDescription)
        }
    }
}

// MARK: - Remote Action Cards

private enum RemoteActionState: String {
    case waiting = "waiting"
    case running = "running"
    case waitingApproval = "waiting approval"
    case ranOnMac = "ran on Mac"
    case failed = "failed"

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

private enum RemoteActionKind: Equatable {
    case notify(title: String, message: String)
    case system(String)
    case volume(Int)
    case spotlight(String)
    case shortcut(String)
}

private struct RemoteActionCard: Identifiable, Equatable {
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

private struct RemoteActionCardView: View {
    let action: RemoteActionCard
    let onRetry: () -> Void

    var body: some View {
        GlassCard(tint: action.state.color, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: action.state.icon)
                        .foregroundStyle(action.state.color)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.title)
                            .font(AppFont.section)
                        Text(action.subtitle)
                            .font(AppFont.label)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(action.state.rawValue)
                        .font(AppFont.tag)
                        .foregroundStyle(action.state.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(action.state.color.opacity(0.12), in: Capsule())
                }
                Text(action.detail)
                    .font(AppFont.label)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack {
                    Text(action.updatedAt, style: .relative)
                        .font(AppFont.tag)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if action.state == .waitingApproval {
                        Button("Review Approval", systemImage: "checkmark.shield") {
                            NotificationCenter.default.post(name: .nativeagentOpenActivity, object: nil)
                        }
                        .buttonStyle(.borderedProminent)
                    } else if action.state == .failed {
                        Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }
}
