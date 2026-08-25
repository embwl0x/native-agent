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
                .pickerStyle(.segmented)
                Text("System follows your iPhone or iPad appearance automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Mac") {
                if let health = store.health {
                    LabeledContent("Status") {
                        Text(health.ok ? "Online" : "Offline")
                            .foregroundStyle(health.ok ? .green : .red)
                    }
                    LabeledContent("App", value: health.app)
                    LabeledContent("Version", value: health.version)
                    LabeledContent("Uptime", value: SettingsMacHealthPresentation.uptimeText(health.uptimeSeconds))
                } else {
                    Text("Health data will appear after iCloud sync.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Connection") {
                LabeledContent("Mode", value: pairingStore.usesICloudTransport ? "iCloud" : "Unpaired")
                LabeledContent("State") {
                    Text(bridgeClient.bridgeStatus.displayName)
                        .foregroundStyle(bridgeClient.bridgeStatus.color)
                }
                let snapshotState = StatusConnectionPresentation.syncState(
                    lastSyncedAt: iCloudSyncEngine.shared.lastSyncAt
                )
                LabeledContent("Last synced") {
                    Text(StatusConnectionPresentation.cardValue(for: snapshotState))
                        .foregroundStyle(
                            StatusConnectionPresentation.needsAttention(snapshotState)
                                ? Color.orange
                                : Color.secondary
                        )
                }
                if let detail = StatusConnectionPresentation.detail(for: snapshotState) {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                LabeledContent("Pairing version", value: "\(pairingStore.knownSecretVersion)")
                if let repairResult {
                    Text(repairResult)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button {
                    // KVS synchronization runs under PairingStore's timeout, so
                    // this never blocks the MainActor. Reload the settings
                    // snapshots afterward: the control promises an iCloud
                    // refresh, not merely a secret-rotation check.
                    Task {
                        isForceRefreshing = true
                        defer { isForceRefreshing = false }

                        let pairingMaterialChanged = await pairingStore.refreshFromKVS()
                        await store.refresh()
                        repairResult = SettingsICloudRefreshPresentation.statusText(
                            pairingMaterialChanged: pairingMaterialChanged,
                            snapshotError: iCloudSyncEngine.shared.syncError
                        )
                    }
                } label: {
                    Label(
                        isForceRefreshing ? "Refreshing from iCloud…" : "Force Refresh from iCloud",
                        systemImage: "arrow.clockwise.icloud"
                    )
                }
                .disabled(isForceRefreshing)
                Button("Re-pair", role: .destructive) { showRePairConfirm = true }
            }

            Section {
                if pushReceipts.isEmpty {
                    Text("No pushes received yet")
                        .font(AppFont.label)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pushReceipts.prefix(8)) { entry in
                        HStack {
                            Text(entry.source)
                                .font(AppFont.label)
                            Spacer()
                            Text(entry.receivedAt, style: .relative)
                                .font(AppFont.label)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Label("Push deliveries", systemImage: "bell.badge")
                    .font(AppFont.section)
            }

            Section("About") {
                if let privacyURL = Self.configuredHTTPSURL(key: "NativeAgentPrivacyPolicyURL") {
                    Link("Privacy Policy", destination: privacyURL)
                } else {
                    Label(
                        SettingsLegalLinksPresentation.unavailableText(for: "Privacy Policy"),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
                if let supportURL = Self.configuredHTTPSURL(key: "NativeAgentSupportURL") {
                    Link("Support", destination: supportURL)
                } else {
                    Label(
                        SettingsLegalLinksPresentation.unavailableText(for: "Support"),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
                LabeledContent(
                    "Version",
                    value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                        as? String ?? "—"
                )
            }
        }
        .navigationTitle("Settings")
        .macSyncErrorBanner()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                MacStatusChip()
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

    func refresh() async {
        isLoading = true
        await iCloudSyncEngine.shared.refreshSettingsSnapshot()
        let sync = iCloudSyncEngine.shared
        trustPolicy = sync.trustPolicy
        // PATCH-2026-05-09: surface synced personality in Settings store.
        personality = sync.personality
        personalitySnapshotSyncedAt = sync.lastSyncAt
        connectors = sync.connectors
        health = sync.health
        isLoading = false
    }
}

// MARK: - Personality detail (read-only; edits via inbox)

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
                                    ? Color.orange
                                    : Color.secondary
                            )
                    }
                    if let detail = PersonalitySnapshotPresentation.detail(for: snapshotState) {
                        Text(detail)
                            .font(AppFont.label)
                            .foregroundStyle(.orange)
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
            } else {
                ContentUnavailableView(
                    "Personality Not Synced",
                    systemImage: "person.crop.circle",
                    description: Text("Personality data will appear after iCloud sync with Mac.")
                )
            }
        }
        .navigationTitle("Personality")
        .navigationBarTitleDisplayMode(.inline)
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
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            // One identity tint for every trait: the value is information,
            // the color is not. Traffic-light tints made low traits (a
            // personality fact) read as warnings (a health problem).
            ProgressView(value: projection.normalizedValue)
                .tint(NativeAgentPalette.agentAccent)
            Text(projection.percentageText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            if projection.wasClamped {
                Text("Clamped")
                    .font(AppFont.tag)
                    .foregroundStyle(.orange)
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
                    title: "Workshop Enabled",
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
                    Section("Workshop Policy") {
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
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView(
                    "Trust Policy Not Synced",
                    systemImage: "lock.shield",
                    description: Text("Trust policy will appear after iCloud sync with Mac.")
                )
            }
        }
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

    var body: some View {
        List {
            if store.connectors.isEmpty {
                AppEmptyState(
                    title: "No connectors",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    kind: .unavailable,
                    description: "Connector status will appear after iCloud sync."
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(store.connectors) { connector in
                    let health = ConnectorHealthPresentation.resolve(
                        enabled: connector.enabled,
                        status: connector.status,
                        healthStatus: connector.healthStatus
                    )
                    GlassCard(tint: health.tint, cornerRadius: 14) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(connector.name).font(AppFont.section)
                                if let kind = connector.kind { Text(kind).font(AppFont.label).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            PulsingDot(color: health.tint)
                            Text(health.displayText)
                                .font(AppFont.label)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                Section {
                    Text("To enable or configure connectors, open the Mac app's Connectors view.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Connectors")
        .navigationBarTitleDisplayMode(.inline)
    }
}
