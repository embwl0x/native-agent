// PATCH-2026-05-19: ui-pull-together SettingsViewFull — app/device settings only.
// Personality, Trust, Providers, and Connectors are first-class More links.
import SwiftUI
import Combine
import NativeAgentShared

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

// MARK: - Settings View

struct SettingsViewFull: View {
    @EnvironmentObject private var pairingStore: PairingStore
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @StateObject private var store = SettingsStore()
    @State private var showRePairSheet = false
    @State private var showRePairConfirm = false
    @State private var repairResult: String?
    @State private var isForceRefreshing = false
    @State private var pushReceipts = PushReceiptLedger.load()
    @AppStorage(NativeAgentAppearance.storageKey) private var appearanceRawValue = NativeAgentAppearance.system.rawValue

    var body: some View {
        List {
            Section("Appearance") {
                Picker("Color scheme", selection: $appearanceRawValue) {
                    ForEach(NativeAgentAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Text("System follows your iPhone or iPad appearance automatically.")
                    .font(.footnote)
                    .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
            }

            Section("Mac") {
                if let health = store.health {
                    LabeledContent("Health snapshot") {
                        Text(health.ok ? "Reported healthy" : "Reported issue")
                            .foregroundStyle(health.ok ? Color.secondary : Color.red)
                    }
                    LabeledContent("App", value: health.app)
                    LabeledContent("Version", value: health.version)
                    LabeledContent("Uptime", value: SettingsMacHealthPresentation.uptimeText(health.uptimeSeconds))
                    if !store.availableFields.contains(.health) {
                        Text("The latest health snapshot could not be read. Showing the last known report.")
                            .font(.footnote)
                            .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                    }
                    Text("Current reachability is shown in Connection below.")
                        .font(.footnote)
                        .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                } else if store.isLoading {
                    ProgressView("Loading health snapshot…")
                } else {
                    Text("No health report has reached this iPhone. Connection below shows the next step.")
                        .font(.footnote)
                        .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                }
            }

            Section("Connection") {
                LabeledContent("Mode") {
                    Text(pairingStore.usesICloudTransport ? "iCloud" : "Unpaired")
                        .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                }
                LabeledContent("State") {
                    Text(pairingStore.isICloudSigned ? bridgeClient.bridgeStatus.displayName : "Not paired")
                        .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                }
                // Connection-wide, so the newest delivery across groups is the
                // honest value here — but still a DELIVERY, not a cache read.
                let snapshotState = StatusConnectionPresentation.syncState(
                    lastSyncedAt: iCloudSyncEngine.shared.lastTransportDeliveryAt
                )
                LabeledContent("Last synced") {
                    Text(StatusConnectionPresentation.cardValue(for: snapshotState))
                        .fontWeight(StatusConnectionPresentation.needsAttention(snapshotState) ? .medium : .regular)
                        .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                }
                if pairingStore.isICloudSigned,
                   let detail = StatusConnectionPresentation.detail(for: snapshotState) {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                }
                if !pairingStore.isICloudSigned {
                    Text("This iPhone has no pairing key for the Mac. Setup checks iCloud and connects both devices using the same Apple Account.")
                        .font(.footnote)
                        .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                    Button("Set up Mac connection") { showRePairSheet = true }
                } else if bridgeClient.bridgeStatus == .offline || bridgeClient.bridgeStatus == .deviceOffline {
                    Text(bridgeClient.bridgeStatus == .deviceOffline
                         ? "This iPhone has no network connection. Reconnect to Wi-Fi or cellular data, then return here."
                         : "The iCloud connection is unavailable. Check the Apple Account and iCloud Drive settings on this iPhone.")
                        .font(.footnote)
                        .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                    Button("Connection setup help") { showRePairSheet = true }
                } else {
                if let repairResult {
                    Text(repairResult)
                        .font(.footnote)
                        .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                }
                Button {
                    // KVS synchronization runs under PairingStore's timeout, so
                    // this never blocks the MainActor. Reload the settings
                    // snapshots afterward: the control promises an iCloud
                    // refresh, not merely a secret-rotation check.
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
                } label: {
                    Label(
                        isForceRefreshing ? "Checking for Mac updates…" : "Check for Mac updates",
                        systemImage: "arrow.clockwise.icloud"
                    )
                }
                .disabled(isForceRefreshing)
                Text("Keep NativeAgent open on the Mac so a current report can reach this iPhone.")
                    .font(.footnote)
                    .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                }
                DisclosureGroup("Connection diagnostics") {
                    LabeledContent("Pairing version", value: "\(pairingStore.knownSecretVersion)")
                    Button("Replace pairing…", role: .destructive) { showRePairConfirm = true }
                }
            }

            Section {
                if pushReceipts.isEmpty {
                    Text("No pushes received yet")
                        .font(.callout)
                        .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                } else {
                    ForEach(pushReceipts.prefix(8)) { entry in
                        MobileAdaptiveRow {
                            Text(entry.source)
                                .font(.callout)
                            Spacer()
                            Text(entry.receivedAt, style: .relative)
                                .font(.callout)
                                .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                        }
                    }
                }
            } header: {
                Label("Push deliveries", systemImage: "bell.badge")
                    .font(.headline)
            }

            Section("About") {
                if let privacyURL = Self.configuredHTTPSURL(key: "NativeAgentPrivacyPolicyURL") {
                    Link("Privacy Policy", destination: privacyURL)
                } else {
                    Label(
                        SettingsLegalLinksPresentation.unavailableText(for: "Privacy Policy"),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                }
                if let supportURL = Self.configuredHTTPSURL(key: "NativeAgentSupportURL") {
                    Link("Support", destination: supportURL)
                } else {
                    Label(
                        SettingsLegalLinksPresentation.unavailableText(for: "Support"),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                }
                LabeledContent(
                    "Version",
                    value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                        as? String ?? "—"
                )
            }
        }
        .mobileReadingScreen()
        .navigationTitle("Settings")
        .macSyncErrorBanner()
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            if pairingStore.isICloudSigned {
                MacStatusChip().frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
            }
            }
        .task {
            pushReceipts = PushReceiptLedger.load()
            await store.refresh()
        }
        .refreshable {
            pushReceipts = PushReceiptLedger.load()
            await store.refresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: PushReceiptLedger.didChange)
                .receive(on: RunLoop.main)
        ) { _ in
            pushReceipts = PushReceiptLedger.load()
        }
        .confirmationDialog("Replace the current pairing?", isPresented: $showRePairConfirm, titleVisibility: .visible) {
            Button("Re-pair", role: .destructive) {
                if pairingStore.clearPairing() {
                    bridgeClient.disconnect()
                    showRePairSheet = true
                } else {
                    repairResult = "The signing key could not be removed securely. Pairing was left unchanged."
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the current signing key. iPhone actions will pause until pairing completes again.")
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
                } else {
                    bridgeClient.disconnect()
                }
            })
            .environmentObject(pairingStore)
            // A full-screen cover sits above ContentView's TabView-safe-area
            // toast host. Re-host the shared queue here so pairing-time
            // delivery and sync feedback remains visible.
            .safeAreaInset(edge: .bottom) {
                iOSSystemToastBar(center: iOSSystemToastCenter.shared)
            }
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

// MARK: - Store

@MainActor
final class SettingsStore: ObservableObject {
    @Published var personality: PersonalityProfile?
    @Published var personalitySnapshotSyncedAt: Date?
    @Published var trustPolicy: TrustPolicy?
    @Published var connectors: [ConnectorRecord] = []
    @Published var health: RuntimeHealth?
    @Published var isLoading = false
    @Published var error: String?
    @Published private(set) var availableFields: Set<SettingsSnapshotRefreshOutcome.Field> = []
    @Published private(set) var hasCompletedRefresh = false
    private var refreshTask: Task<SettingsSnapshotRefreshOutcome, Never>?
    private let refreshSnapshot: @MainActor () async -> SettingsSnapshotRefreshOutcome

    init(
        refreshSnapshot: @escaping @MainActor () async -> SettingsSnapshotRefreshOutcome = {
            await iCloudSyncEngine.shared.refreshSettingsSnapshot()
        }
    ) {
        self.refreshSnapshot = refreshSnapshot
    }

    @discardableResult
    func refresh() async -> SettingsSnapshotRefreshOutcome {
        if let refreshTask { return await refreshTask.value }
        isLoading = true
        let task = Task { @MainActor in
            let outcome = await refreshSnapshot()
            error = outcome.feedbackMessage
            hasCompletedRefresh = true
            guard outcome.state != .superseded else { return outcome }
            let sync = iCloudSyncEngine.shared
            availableFields = outcome.availableFields
            trustPolicy = sync.trustPolicy
            // A partial read has no per-file source timestamp. Do not borrow
            // an unrelated global sync receipt to make Personality newer.
            personality = sync.personality
            if outcome.availableFields.contains(.personality) {
                personalitySnapshotSyncedAt = outcome.state == .refreshed ? sync.lastSyncAt : nil
            }
            connectors = sync.connectors
            health = sync.health
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

// MARK: - Personality detail (read-only; edits via inbox)

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

enum PersonalitySnapshotPresentation {
    static func state(
        lastSyncedAt: Date?,
        now: Date = Date()
    ) -> StatusConnectionPresentation.SyncState {
        StatusConnectionPresentation.syncState(lastSyncedAt: lastSyncedAt, now: now)
    }

    static func value(for state: StatusConnectionPresentation.SyncState) -> String {
        StatusConnectionPresentation.cardValue(for: state)
    }

    static func detail(for state: StatusConnectionPresentation.SyncState) -> String? {
        switch state {
        case .current:
            return nil
        case .stale:
            return "Traits may be out of date until a newer Mac personality snapshot arrives."
        case .neverSynced:
            return "Personality snapshot freshness is unknown; these traits may be out of date."
        case .clockMismatch:
            return "Personality snapshot time cannot be compared with this phone; these traits may be out of date."
        }
    }

    static func needsAttention(_ state: StatusConnectionPresentation.SyncState) -> Bool {
        StatusConnectionPresentation.needsAttention(state)
    }
}

struct PersonalityDetailView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        List {
            if let p = store.personality {
                if store.hasCompletedRefresh, !store.availableFields.contains(.personality) {
                    Label("Personality could not be refreshed. Showing the last known profile.", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                }
                let snapshotState = PersonalitySnapshotPresentation.state(
                    lastSyncedAt: store.personalitySnapshotSyncedAt
                )
                Section("Identity") {
                    LabeledContent("Name", value: p.name)
                    LabeledContent("Kind", value: p.personaKind)
                    LabeledContent("Snapshot") {
                        Text(PersonalitySnapshotPresentation.value(for: snapshotState))
                            .foregroundStyle(
                                PersonalitySnapshotPresentation.needsAttention(snapshotState)
                                    ? Color.secondary
                                    : Color.secondary
                            )
                    }
                    if let detail = PersonalitySnapshotPresentation.detail(for: snapshotState) {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                    }
                }
                Section("Essence") {
                    Text(p.essence).font(.body)
                }
                Section("Voice") {
                    Text(p.voice).font(.body)
                }
                Section {
                    TraitRow(label: "Warmth", value: p.traits.warmth)
                    TraitRow(label: "Directness", value: p.traits.directness)
                    TraitRow(label: "Humor", value: p.traits.humor)
                    TraitRow(label: "Proactivity", value: p.traits.proactivity)
                    TraitRow(label: "Rigor", value: p.traits.rigor)
                    TraitRow(label: "Autonomy", value: p.traits.autonomy)
                    TraitRow(label: "Creativity", value: p.traits.creativity)
                    TraitRow(label: "Brevity", value: p.traits.brevity)
                } header: {
                    Text("Traits")
                } footer: {
                    // Answer "can I change these?" where the question arises —
                    // not in a detached section below.
                    Text("Mirrored from the Mac. Edit in the Mac app's Personality view.")
                }
            } else if store.isLoading || !store.hasCompletedRefresh {
                ProgressView("Loading Personality…")
            } else {
                MobileReadingEmptyState(
                    title: "Personality unavailable",
                    systemImage: "person.crop.circle",
                    kind: .unavailable,
                    description: "The personality snapshot could not be read. Keep the Mac app open and try again.",
                    action: ("Try Again", "arrow.clockwise", { Task { await store.refresh() } })
                )
            }
        }
        .mobileReadingScreen()
        .navigationTitle("Personality")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
    }
}

struct TraitValuePresentation: Equatable {
    let normalizedValue: Double
    let wasClamped: Bool
    let percentageText: String
    let warningText: String?

    static func project(_ rawValue: Double) -> TraitValuePresentation {
        guard rawValue.isFinite else {
            return .init(
                normalizedValue: 0,
                wasClamped: true,
                percentageText: "0%",
                warningText: "The Mac reported an invalid trait value; displaying 0%."
            )
        }

        let normalizedValue = min(max(rawValue, 0), 1)
        guard normalizedValue == rawValue else {
            return .init(
                normalizedValue: normalizedValue,
                wasClamped: true,
                percentageText: String(format: "%.0f%%", normalizedValue * 100),
                warningText: "The Mac reported a trait value outside 0–100%; displaying a clamped value."
            )
        }

        return .init(
            normalizedValue: normalizedValue,
            wasClamped: false,
            percentageText: String(format: "%.0f%%", normalizedValue * 100),
            warningText: nil
        )
    }
}

struct TraitRow: View {
    let label: String
    let value: Double

    var body: some View {
        let projection = TraitValuePresentation.project(value)
        MobileAdaptiveRow {
            Text(label).fixedSize(horizontal: false, vertical: true)
            // One identity tint for every trait: the value is information,
            // the color is not. Traffic-light tints made low traits (a
            // personality fact) read as warnings (a health problem).
            ProgressView(value: projection.normalizedValue)
                .tint(.secondary)
            Text(projection.percentageText)
                .font(.caption)
                .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if projection.wasClamped {
                Text("Clamped")
                    .font(.caption)
                    .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(label): \(projection.percentageText)"
                + (projection.warningText.map { " — \($0)" } ?? "")
        )
    }
}

// MARK: - Trust policy

/// The synced policy format is versioned: an absent Boolean means the Mac did
/// not publish that setting, not that it explicitly disabled it.
enum TrustPolicyDetailPresentation {
    enum BooleanSection: String, Equatable {
        case permission
        case workshop
        case training
    }

    struct BooleanSetting: Identifiable, Equatable {
        let section: BooleanSection
        let title: String
        let value: String

        var id: String { "\(section.rawValue).\(title)" }
    }

    static func booleanValue(_ value: Bool?, enabled: String, disabled: String) -> String {
        guard let value else { return "Not reported by the Mac" }
        return value ? enabled : disabled
    }

    /// Keep every optional Boolean on the same tri-state path before the view
    /// groups it into sections. An omitted field remains visibly unknown;
    /// it cannot be rendered as an intentional disabled setting.
    static func booleanSettings(for policy: TrustPolicy) -> [BooleanSetting] {
        var settings = [
            BooleanSetting(
                section: .permission,
                title: "Developer Mode",
                value: booleanValue(policy.developerMode, enabled: "On", disabled: "Off")
            ),
            BooleanSetting(
                section: .permission,
                title: "Require Backups",
                value: booleanValue(policy.effectiveRequireBackups, enabled: "Yes", disabled: "No")
            ),
        ]
        if let workshop = policy.workshopPolicy {
            settings += [
                BooleanSetting(
                    section: .workshop,
                    title: "Desk Enabled",
                    value: booleanValue(workshop.enabled, enabled: "Yes", disabled: "No")
                ),
                BooleanSetting(
                    section: .workshop,
                    title: "Show Timeline",
                    value: booleanValue(workshop.showTimeline, enabled: "Yes", disabled: "No")
                ),
            ]
        }
        if let training = policy.trainingPolicy {
            settings += [
                BooleanSetting(
                    section: .training,
                    title: "Autonomous Training",
                    value: booleanValue(training.autonomousTraining, enabled: "On", disabled: "Off")
                ),
                BooleanSetting(
                    section: .training,
                    title: "Dream Scheduler",
                    value: booleanValue(training.dreamScheduler, enabled: "On", disabled: "Off")
                ),
            ]
        }
        return settings
    }
}

/// A policy snapshot can predate a field. Keep absent text values visibly
/// unknown instead of making a missing default look like an intentional one.
enum TrustPolicySummaryPresentation {
    static let unknownValue = "Not reported by the Mac"

    static func textValue(_ value: String?) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return unknownValue
        }
        return value
    }
}

struct TrustPolicyView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        List {
            if let policy = store.trustPolicy {
                let booleanSettings = TrustPolicyDetailPresentation.booleanSettings(for: policy)
                Section("Permission Level") {
                    LabeledContent(
                        "Level",
                        value: TrustPolicySummaryPresentation.textValue(policy.permissionLevel)
                    )
                    LabeledContent(
                        "Autonomy Default",
                        value: TrustPolicySummaryPresentation.textValue(policy.autonomyDefault)
                    )
                    LabeledContent(
                        "Outside Default",
                        value: TrustPolicySummaryPresentation.textValue(policy.effectiveOutsideDefault)
                    )
                    ForEach(booleanSettings.filter { $0.section == .permission }) { setting in
                        LabeledContent(setting.title, value: setting.value)
                    }
                }
                if policy.workshopPolicy != nil {
                    Section("Desk Policy") {
                        ForEach(booleanSettings.filter { $0.section == .workshop }) { setting in
                            LabeledContent(setting.title, value: setting.value)
                        }
                    }
                }
                if policy.trainingPolicy != nil {
                    Section("Training Policy") {
                        ForEach(booleanSettings.filter { $0.section == .training }) { setting in
                            LabeledContent(setting.title, value: setting.value)
                        }
                    }
                }
                Section {
                    Text("To change trust policy, open the Mac app's Trust view.")
                        .font(.footnote).foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                }
            } else {
                ContentUnavailableView(
                    "Trust Policy Not Synced",
                    systemImage: "lock.shield",
                    description: Text("Trust policy will appear after iCloud sync with Mac.")
                )
            }
        }
        .mobileReadingScreen()
        .navigationTitle("Trust Policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Connectors

enum ConnectorHealthPresentation: Equatable {
    case disabled
    case healthy(String)
    case needsAttention(String)
    case reportedStatus(String)
    case unknown

    static func resolve(
        enabled: Bool?,
        status: String? = nil,
        healthStatus: String?
    ) -> ConnectorHealthPresentation {
        if enabled == false { return .disabled }

        if let health = normalized(healthStatus) {
            switch health.lowercased() {
            case "ok", "healthy", "ready", "connected", "active":
                return .healthy(health)
            default:
                return .needsAttention(health)
            }
        }

        // A connector's published status is useful context, but without a
        // health result it is not proof that the live integration works.
        if let status = normalized(status) { return .reportedStatus(status) }
        return .unknown
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    var displayText: String {
        switch self {
        case .disabled:
            return "Disabled"
        case .healthy(let health), .needsAttention(let health):
            return health.replacingOccurrences(of: "_", with: " ").capitalized
        case .reportedStatus(let status):
            return "Status: \(status.replacingOccurrences(of: "_", with: " ").capitalized)"
        case .unknown:
            return "Health unknown"
        }
    }

    var tint: Color {
        switch self {
        case .healthy:
            return .green
        case .disabled, .reportedStatus:
            return .secondary
        case .needsAttention, .unknown:
            return .orange
        }
    }
}

struct ConnectorsView: View {
    @ObservedObject var store: SettingsStore

    private var presentation: SettingsSnapshotContentPresentation {
        .state(
            hasContent: !store.connectors.isEmpty,
            fieldAvailable: store.availableFields.contains(.connectors),
            isLoading: store.isLoading,
            hasCompletedRefresh: store.hasCompletedRefresh
        )
    }

    var body: some View {
        List {
            switch presentation {
            case .loading:
                ProgressView("Loading connectors…")
            case .unavailable:
                MobileReadingEmptyState(
                    title: "Connectors unavailable",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    kind: .unavailable,
                    description: "The connector snapshot could not be read. Keep the Mac app open and try again.",
                    action: ("Try Again", "arrow.clockwise", { Task { await store.refresh() } })
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            case .empty:
                MobileReadingEmptyState(
                    title: "No connectors",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    kind: .empty,
                    description: "The Mac has not published any connectors. Configure them in the Mac app's Connectors view."
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            case .content, .stale:
                if presentation == .stale {
                    Label("Connectors could not be refreshed. Showing the last known rows.", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                }
                ForEach(store.connectors) { connector in
                    let health = ConnectorHealthPresentation.resolve(
                        enabled: connector.enabled,
                        status: connector.status,
                        healthStatus: connector.healthStatus
                    )
                    MobileReadingSurface {
                        MobileAdaptiveRow {
                            VStack(alignment: .leading) {
                                Text(connector.name).font(.headline)
                                if let kind = connector.kind { Text(kind).font(.callout).foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary) }
                            }
                            Spacer()
                            Image(systemName: "circle.fill").font(.caption2).foregroundStyle(.secondary)
                                .opacity(health == .disabled ? 0.5 : 1)
                                .accessibilityLabel(health.displayText)
                            Text(health.displayText)
                                .font(.callout)
                                .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                Section {
                    Text("To enable or configure connectors, open the Mac app's Connectors view.")
                        .font(.footnote).foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                }
            }
        }
        .mobileReadingScreen()
        .navigationTitle("Connectors")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
    }
}
