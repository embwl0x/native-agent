// Settings owns Telegram, Providers and Mac settings; More links to Personality, Trust and Connectors.
import SwiftUI
import Combine
import NativeAgentShared
// Blueprint: | `SettingsViewFull.swift` | Device settings, shared SettingsStore refresh/loading and snapshot availability presentation |

enum SettingsMacHealthPresentation {
    static func uptimeText(_ seconds: Double) -> String {
        let formatted = UserDisplayFormatters.humanizeDuration(seconds)
        return formatted.isEmpty ? "Unknown" : formatted
    }
}

enum SettingsLegalLinksPresentation {
    static func destination(for rawValue: String?) -> URL? {
        guard let rawValue,
              let url = URL(string: rawValue),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    static func unavailableText(for label: String) -> String {
        "\(label) link is unavailable in this build."
    }
}

struct SettingsViewFull: View {
    var opensConnection = false
    @EnvironmentObject private var pairingStore: PairingStore
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @StateObject private var store = SettingsStore()
    @ObservedObject private var turnActivity = PhoneTurnActivity.shared
    @State private var showRePairSheet = false
    @State private var repairResult: String?
    @State private var isForceRefreshing = false
    @State private var pushReceipts = PushReceiptLedger.load()
    @AppStorage(NativeAgentAppearance.storageKey) private var appearanceRawValue = NativeAgentAppearance.system.rawValue

    var body: some View {
        ScrollViewReader { proxy in
            settingsPage.onAppear {
                if opensConnection { proxy.scrollTo("connection", anchor: .top) }
            }
        }
    }

    private var settingsPage: some View {
        AlivePage(title: "Settings", line: "This iPhone, its link to the Mac, and the Mac's own settings.") {
            AliveSection("Appearance") {
                MobileAdaptiveRow(spacing: 12) {
                    Text("Color scheme").foregroundStyle(AlivePalette.text)
                    Spacer(minLength: 8)
                    Picker("Color scheme", selection: $appearanceRawValue) {
                        ForEach(NativeAgentAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .hazeTinted()
                }
                .padding(.horizontal, AliveMetrics.rowInsetH)
                .padding(.top, 6)
                Text("System follows your iPhone or iPad appearance automatically.")
                    .font(.footnote)
                    .foregroundStyle(AlivePalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, AliveMetrics.rowInsetH)
                    .padding(.bottom, AliveMetrics.rowInsetV)
                AliveDivider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Haze").foregroundStyle(AlivePalette.text)
                    HazeSwatches()
                    Text("The light that drifts behind every screen. Same colors as on the Mac.")
                        .font(.footnote)
                        .foregroundStyle(AlivePalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .aliveRow()
            }

            AliveSection("Mac") {
                if let health = store.sync.health {
                    AliveValueRow(label: "Health", value: health.ok ? "Reported healthy" : "Reported issue",
                                 valueColor: health.ok ? AlivePalette.secondary : NativeAgentMobileTheme.Colors.trouble)
                    AliveDivider()
                    AliveValueRow(label: "App", value: health.app)
                    AliveDivider()
                    AliveValueRow(label: "Version", value: health.version)
                    AliveDivider()
                    AliveValueRow(label: "Uptime", value: SettingsMacHealthPresentation.uptimeText(health.uptimeSeconds))
                    if !store.availableFields.contains(.health) {
                        AliveDivider()
                        AliveNote("The latest health snapshot could not be read. Showing the last known report.")
                    }
                } else if store.isLoading {
                    ProgressView("Loading health snapshot…")
                        .tint(AlivePalette.secondary)
                        .foregroundStyle(AlivePalette.secondary)
                        .aliveRow()
                } else {
                    AliveNote("No health report has reached this iPhone yet. Connection below shows the next step.")
                }
            }

            connectionGroup.id("connection")
            AliveSection("On your Mac") {
                macLink("Telegram", "Telegram settings on your Mac") { TelegramView() }
                AliveDivider()
                macLink("Providers", "The models I think with") { ProviderSettingsView() }
            }
            MobileAppSettingsSections()
            PhonePlacesSettings()
            AliveSection("Live Activities") {
                Toggle("Show task names on the Lock Screen", isOn: Binding(
                    get: { turnActivity.isEnabled }, set: { turnActivity.setEnabled($0) }))
                    .aliveRow()
                AliveNote("Includes work started on the Mac, Telegram, helpers and agent bridges. Task names may be visible while this iPhone is locked. Without an APNs key on the Mac, activities start when this app is open or next wakes; updates can be delayed while it is asleep.")
                if let error = turnActivity.errorMessage { AliveNote(error) }
            }

            AliveSection("Recent pushes") {
                if pushReceipts.isEmpty {
                    AliveNote("No pushes received yet.")
                } else {
                    ForEach(Array(pushReceipts.prefix(8).enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { AliveDivider() }
                        MobileAdaptiveRow {
                            Text(entry.source).foregroundStyle(AlivePalette.text)
                            Spacer()
                            Text(entry.receivedAt, style: .relative)
                                .foregroundStyle(AlivePalette.secondary)
                        }
                        .font(.callout)
                        .aliveRow()
                    }
                }
            }

            AliveSection("About") {
                aboutLink("Privacy Policy", key: "NativeAgentPrivacyPolicyURL")
                AliveDivider()
                aboutLink("Support", key: "NativeAgentSupportURL")
                AliveDivider()
                AliveValueRow(
                    label: "Version",
                    value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                        as? String ?? "—"
                )
            }
        }
        .macSyncErrorBanner()
        .task {
            pushReceipts = PushReceiptLedger.load()
            async let macSettings: Void = iCloudSyncEngine.shared.refreshAppSettings()
            await store.refresh()
            await macSettings
        }
        .refreshable {
            pushReceipts = PushReceiptLedger.load()
            async let macSettings: Void = iCloudSyncEngine.shared.refreshAppSettings()
            await store.refresh()
            await macSettings
        }
        .onReceive(
            NotificationCenter.default.publisher(for: PushReceiptLedger.didChange)
                .receive(on: RunLoop.main)
        ) { _ in
            pushReceipts = PushReceiptLedger.load()
        }
        .fullScreenCover(isPresented: $showRePairSheet) {
            PairingView(onSkip: {
                showRePairSheet = false
            }, onPaired: {
                showRePairSheet = false
                UserDefaults.standard.set(false, forKey: "NativeAgentMobile.pairingSkipped")
                iCloudSyncEngine.shared.pairingStore = pairingStore
                iCloudBridge.shared.pairingStore = pairingStore
                if pairingStore.usesICloudTransport {
                    bridgeClient.configureICloud()
                    bridgeClient.recordMacConfirmation()
                } else {
                    bridgeClient.disconnect()
                }
            })
            .environmentObject(pairingStore)
            // A full-screen cover sits above ContentView's TabView-safe-area
            // toast host. Re-host the shared queue here so pairing-time
            // delivery and sync feedback remains visible.
            .safeAreaInset(edge: .bottom) {
                iOSSystemToastBar(center: SystemToastCenter.shared)
            }
        }
    }

    private func macLink<Destination: View>(_ title: String, _ detail: String,
                                            @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            AliveRow(title, detail: detail) { AliveChevron() }
        }
        .aliveRowButtonStyle()
    }

    private var connectionGroup: some View {
        // Connection-wide, so the newest delivery across groups is the
        // honest value here — but still a DELIVERY, not a cache read.
        let snapshotState = StatusConnectionPresentation.syncState(
            lastSyncedAt: iCloudSyncEngine.shared.lastTransportDeliveryAt
        )
        return AliveSection("Connection") {
            // The connection is three facts, each with who can fix it and how.
            ForEach(bridgeClient.connection.facts, id: \.label) { item in
                AliveConnectionFactLine(label: item.label, fact: item.fact)
                AliveDivider()
            }
            AliveValueRow(label: "Last synced", value: StatusConnectionPresentation.cardValue(for: snapshotState),
                         emphasized: StatusConnectionPresentation.needsAttention(snapshotState))
            if let repairResult { AliveNote(repairResult) }
            if pairingStore.isICloudSigned,
               let detail = StatusConnectionPresentation.detail(for: snapshotState) {
                AliveNote(detail)
            }
            AliveDivider()
            if !bridgeClient.connection.holds {
                repairConnectionRow
                AliveTapRow(title: "Pair with Mac") { showRePairSheet = true }
                AliveDivider()
            }
            if !pairingStore.isICloudSigned {
                AliveNote("This iPhone has no pairing key for the Mac. Setup checks iCloud and connects both devices using the same Apple Account.")
                AliveTapRow(title: "Set up Mac connection") { showRePairSheet = true }
            } else if bridgeClient.connection.transport.state == .broken {
                AliveNote(bridgeClient.connection.transport.lever ?? bridgeClient.connection.transport.line)
                AliveTapRow(title: "Connection setup help") { showRePairSheet = true }
            } else {
                AliveTapRow(title: isForceRefreshing ? "Checking for Mac updates…" : "Check for Mac updates") {
                    // Refresh both pairing material and settings snapshots without blocking MainActor.
                    Task {
                        guard !isForceRefreshing else { return }
                        isForceRefreshing = true
                        defer { isForceRefreshing = false }

                        let pairingMaterialChanged = await pairingStore.refreshFromKVS()
                        let settingsOutcome = await store.refresh()
                        repairResult = SettingsICloudRefreshPresentation.statusText(
                            pairingMaterialChanged: pairingMaterialChanged,
                            snapshotError: settingsOutcome.feedbackMessage
                        )
                    }
                }
                .disabled(isForceRefreshing)
                AliveNote("Keep NativeAgent open on the Mac so a current report can reach this iPhone.")
            }
            AliveDivider()
            DisclosureGroup {
                repairConnectionRow
                HStack {
                    Text("Pairing version").foregroundStyle(AlivePalette.text)
                    Spacer()
                    Text("\(pairingStore.knownSecretVersion)").foregroundStyle(AlivePalette.secondary)
                }
                .padding(.top, 10)
                .accessibilityElement(children: .combine)
            } label: {
                Text("Diagnostics").foregroundStyle(AlivePalette.text)
            }
            .tint(AlivePalette.secondary)
            .aliveRow()
        }
    }

    private var repairConnectionRow: some View {
        AliveTapRow(title: pairingStore.isRepairingConnection ? "Repairing connection…" : "Repair connection") {
            Task {
                repairResult = nil
                do {
                    try await bridgeClient.repairConnection()
                    showRePairSheet = true
                } catch {
                    repairResult = "Connection repair couldn’t finish: \(error.localizedDescription)"
                }
            }
        }
        .disabled(pairingStore.isRepairingConnection || isForceRefreshing)
    }

    @ViewBuilder
    private func aboutLink(_ title: String, key: String) -> some View {
        if let url = Self.configuredHTTPSURL(key: key) {
            Link(destination: url) {
                HStack {
                    Text(title).foregroundStyle(AlivePalette.text)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AlivePalette.secondary)
                        .accessibilityHidden(true)
                }
                .aliveRow()
                .contentShape(Rectangle())
            }
            .aliveRowButtonStyle()
        } else {
            AliveNote(SettingsLegalLinksPresentation.unavailableText(for: title))
        }
    }

    private static func configuredHTTPSURL(key: String) -> URL? {
        SettingsLegalLinksPresentation.destination(
            for: Bundle.main.object(forInfoDictionaryKey: key) as? String
        )
    }
}

enum SettingsICloudRefreshPresentation {
    static func statusText(pairingMaterialChanged: Bool, snapshotError: String?) -> String {
        let pairingStatus = pairingMaterialChanged
            ? "New pairing material installed."
            : "No new pairing material was installed."

        guard let snapshotError,
              !snapshotError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "\(pairingStatus) Settings snapshot reload completed."
        }

        return "\(pairingStatus) \(snapshotError)"
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    let sync: iCloudSyncEngine
    @Published var isLoading = false
    @Published var error: String?
    @Published private(set) var availableFields: Set<SettingsSnapshotRefreshOutcome.Field> = []
    @Published private(set) var hasCompletedRefresh = false
    private var refreshTask: Task<SettingsSnapshotRefreshOutcome, Never>?
    init(sync: iCloudSyncEngine = .shared) {
        self.sync = sync
    }

    @discardableResult
    func refresh() async -> SettingsSnapshotRefreshOutcome {
        if let refreshTask { return await refreshTask.value }
        isLoading = true
        let task = Task { @MainActor in
            let outcome = await sync.refreshSettingsSnapshot()
            error = outcome.feedbackMessage
            hasCompletedRefresh = true
            guard outcome.state != .superseded else { return outcome }
            availableFields = outcome.availableFields
            return outcome
        }
        refreshTask = task
        defer {
            refreshTask = nil
            isLoading = false
        }
        return await task.value
    }
}

enum SettingsSnapshotContentPresentation: Equatable {
    case loading, unavailable, empty, content, stale

    static func state(
        hasContent: Bool,
        fieldAvailable: Bool,
        isLoading: Bool,
        hasCompletedRefresh: Bool
    ) -> Self {
        if hasContent {
            return hasCompletedRefresh && !fieldAvailable ? .stale : .content
        }
        if isLoading || !hasCompletedRefresh { return .loading }
        return fieldAvailable ? .empty : .unavailable
    }
}
