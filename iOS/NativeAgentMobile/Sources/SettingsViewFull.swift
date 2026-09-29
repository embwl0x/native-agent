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
    @ObservedObject private var turnActivity = PhoneTurnActivity.shared
    @State private var showRePairSheet = false
    @State private var repairResult: String?
    @State private var isForceRefreshing = false
    @State private var pushReceipts = PushReceiptLedger.load()
    @AppStorage(NativeAgentAppearance.storageKey) private var appearanceRawValue = NativeAgentAppearance.system.rawValue

    var body: some View {
        AlivePage(title: "Settings", line: "This iPhone and its link to the Mac.") {
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
                if let health = store.health {
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

            connectionGroup
            PhonePlacesSettings()
            if let error = turnActivity.errorMessage {
                AliveSection("Live Activity") { AliveNote(error) }
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

    private var connectionGroup: some View {
        // Connection-wide, so the newest delivery across groups is the
        // honest value here — but still a DELIVERY, not a cache read.
        let snapshotState = StatusConnectionPresentation.syncState(
            lastSyncedAt: iCloudSyncEngine.shared.lastTransportDeliveryAt
        )
        return AliveSection("Connection") {
            AliveValueRow(label: "State",
                         value: AliveConnection.line(for: bridgeClient.bridgeStatus, paired: pairingStore.isICloudSigned))
            AliveDivider()
            AliveValueRow(label: "Last synced", value: StatusConnectionPresentation.cardValue(for: snapshotState),
                         emphasized: StatusConnectionPresentation.needsAttention(snapshotState))
            if pairingStore.isICloudSigned,
               let detail = StatusConnectionPresentation.detail(for: snapshotState) {
                AliveNote(detail)
            }
            AliveDivider()
            if !pairingStore.isICloudSigned {
                AliveNote("This iPhone has no pairing key for the Mac. Setup checks iCloud and connects both devices using the same Apple Account.")
                AliveTapRow(title: "Set up Mac connection") { showRePairSheet = true }
            } else if bridgeClient.bridgeStatus == .offline || bridgeClient.bridgeStatus == .deviceOffline {
                AliveNote(bridgeClient.bridgeStatus == .deviceOffline
                         ? "This iPhone has no network connection. Reconnect to Wi-Fi or cellular data, then return here."
                         : "The iCloud connection is unavailable. Check the Apple Account and iCloud Drive settings on this iPhone.")
                AliveTapRow(title: "Connection setup help") { showRePairSheet = true }
            } else {
                if let repairResult { AliveNote(repairResult) }
                AliveTapRow(title: isForceRefreshing ? "Checking for Mac updates…" : "Check for Mac updates") {
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
                }
                .disabled(isForceRefreshing)
                AliveNote("Keep NativeAgent open on the Mac so a current report can reach this iPhone.")
            }
            AliveDivider()
            DisclosureGroup {
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
        AlivePage(title: "Personality", line: "How I think and sound.") {
            if let p = store.personality {
                let snapshotState = PersonalitySnapshotPresentation.state(
                    lastSyncedAt: store.personalitySnapshotSyncedAt
                )
                AliveSection("Identity") {
                    if store.hasCompletedRefresh, !store.availableFields.contains(.personality) {
                        AliveNote("Personality could not be refreshed. Showing the last known profile.")
                        AliveDivider()
                    }
                    AliveValueRow(label: "Name", value: p.name)
                    AliveDivider()
                    AliveValueRow(label: "Kind", value: p.personaKind)
                    AliveDivider()
                    AliveValueRow(label: "Snapshot", value: PersonalitySnapshotPresentation.value(for: snapshotState),
                                 emphasized: PersonalitySnapshotPresentation.needsAttention(snapshotState))
                    if let detail = PersonalitySnapshotPresentation.detail(for: snapshotState) {
                        AliveNote(detail)
                    }
                }
                AliveSection("Essence") {
                    MorePassage(text: p.essence)
                }
                AliveSection("Voice") {
                    MorePassage(text: p.voice)
                }
                // Answer "can I change these?" where the question arises —
                // not in a detached section below.
                AliveSection("Traits", footer: "Mirrored from the Mac. Edit in the Mac app's Personality view.") {
                    let traits: [(String, Double)] = [
                        ("Warmth", p.traits.warmth), ("Directness", p.traits.directness),
                        ("Humor", p.traits.humor), ("Proactivity", p.traits.proactivity),
                        ("Rigor", p.traits.rigor), ("Autonomy", p.traits.autonomy),
                        ("Creativity", p.traits.creativity), ("Brevity", p.traits.brevity),
                    ]
                    VStack(spacing: 14) {
                        ForEach(traits, id: \.0) { trait in
                            TraitRow(label: trait.0, value: trait.1)
                        }
                    }
                    .aliveRow()
                }
            } else if store.isLoading || !store.hasCompletedRefresh {
                ProgressView("Loading Personality…")
                    .tint(AlivePalette.secondary)
                    .foregroundStyle(AlivePalette.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else {
                AliveCalmState(
                    title: "Not here yet",
                    line: "My personality comes over from the Mac. Keep the Mac app open and try again.",
                    actionTitle: "Try again",
                    action: { Task { await store.refresh() } }
                )
            }
        }
        .refreshable { await store.refresh() }
    }
}

/// A paragraph inside a card, at reading size.
private struct MorePassage: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.body)
            .lineSpacing(3)
            .foregroundStyle(AlivePalette.text)
            .fixedSize(horizontal: false, vertical: true)
            .aliveRow()
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
        MobileAdaptiveRow(spacing: 12) {
            Text(label)
                .foregroundStyle(AlivePalette.text)
                .frame(minWidth: 96, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            // One ink for every trait: the value is information, the color
            // is not. Traffic-light tints made low traits (a personality
            // fact) read as warnings (a health problem).
            Capsule()
                .fill(AlivePalette.divider)
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule()
                            .fill(AlivePalette.secondary)
                            .frame(width: geo.size.width * projection.normalizedValue)
                    }
                }
            Text(projection.wasClamped ? "\(projection.percentageText) clamped" : projection.percentageText)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(AlivePalette.secondary)
                .frame(minWidth: 40, alignment: .trailing)
                .fixedSize(horizontal: true, vertical: true)
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
        AlivePage(title: "Trust", line: "What I may do on my own.") {
            if let policy = store.trustPolicy {
                MobileTrustEditor(policy: policy, store: store)
            } else {
                AliveCalmState(
                    title: "Not here yet",
                    line: "My trust policy comes over from the Mac and appears after the next iCloud sync."
                )
            }
        }
        .refreshable { await store.refresh() }
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
            return "Off"
        case .healthy(let health), .needsAttention(let health):
            return Self.word(health)
        case .reportedStatus(let status):
            return "Status: \(Self.word(status))"
        case .unknown:
            return "Health unknown"
        }
    }

    /// The Mac's words for the same states (Connectors on the Mac).
    static func word(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "needs_auth", "auth_required", "needs_sign_in": return "Needs sign-in"
        case "connected", "live", "ok", "healthy", "active": return "Connected"
        case "ready": return "Ready"
        case "connecting", "starting": return "Connecting"
        case "disconnected", "offline": return "Disconnected"
        case "disabled": return "Off"
        case "failed", "error", "unavailable": return "Unavailable"
        case "unverified": return "Not checked"
        case let other: return AliveWords.humanized(other)
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
        AlivePage(title: "Connectors", line: "The services I can reach.") {
            switch presentation {
            case .loading:
                ProgressView("Loading connectors…")
                    .tint(AlivePalette.secondary)
                    .foregroundStyle(AlivePalette.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            case .unavailable:
                AliveCalmState(
                    title: "Not here yet",
                    line: "My connectors come over from the Mac. Keep the Mac app open and try again.",
                    actionTitle: "Try again",
                    action: { Task { await store.refresh() } }
                )
            case .empty:
                AliveCalmState(
                    title: "No connectors yet",
                    line: "Connect services in the Mac app's Connectors view and they show up here."
                )
            case .content, .stale:
                AliveSection(nil) {
                    if presentation == .stale {
                        AliveNote("Connectors could not be refreshed. Showing the last known rows.")
                        AliveDivider()
                    }
                    ForEach(Array(store.connectors.enumerated()), id: \.element.id) { index, connector in
                        if index > 0 { AliveDivider() }
                        MobileConnectorRow(connector: connector)
                    }
                }
            }
        }
        .refreshable { await store.refresh() }
    }
}
