// PATCH-2026-05-19: ui-pull-together SettingsViewFull — app/device settings only.
// Personality, Trust, Providers, and Connectors are first-class More links.
import SwiftUI
import NativeAgentShared

// MARK: - Settings View

struct SettingsViewFull: View {
    @EnvironmentObject private var pairingStore: PairingStore
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @StateObject private var store = SettingsStore()
    @State private var showRePairSheet = false
    @State private var showRePairConfirm = false
    @State private var repairResult: String?
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
                    LabeledContent("Uptime", value: String(format: "%.0fs", health.uptimeSeconds))
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
                if let syncAt = iCloudSyncEngine.shared.lastSyncAt {
                    LabeledContent("Last synced") {
                        Text(syncAt, style: .relative)
                            .foregroundStyle(Date().timeIntervalSince(syncAt) > 30 ? .orange : .secondary)
                    }
                }
                LabeledContent("Pairing version", value: "\(pairingStore.knownSecretVersion)")
                if let repairResult {
                    Text(repairResult)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Force Refresh from iCloud", systemImage: "arrow.clockwise.icloud") {
                    // 2026-07-21 audit: async now — KVS synchronize runs under
                    // a timeout, never blocking the MainActor.
                    Task {
                        repairResult = await pairingStore.refreshFromKVS()
                            ? "New pairing material installed from iCloud."
                            : "Pairing material is unchanged or unavailable."
                    }
                }
                Button("Re-pair", role: .destructive) { showRePairConfirm = true }
            }

            Section {
                let receipts = PushReceiptLedger.load()
                if receipts.isEmpty {
                    Text("No pushes received yet")
                        .font(AppFont.label)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(receipts.prefix(8)) { entry in
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
                }
                if let supportURL = Self.configuredHTTPSURL(key: "NativeAgentSupportURL") {
                    Link("Support", destination: supportURL)
                }
                LabeledContent(
                    "Version",
                    value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                        as? String ?? "—"
                )
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.refresh() }
        .refreshable { await store.refresh() }
        .confirmationDialog("Replace the current pairing?", isPresented: $showRePairConfirm, titleVisibility: .visible) {
            Button("Re-pair", role: .destructive) {
                bridgeClient.disconnect()
                pairingStore.clearPairing()
                showRePairSheet = true
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
        }
    }

    private static func configuredHTTPSURL(key: String) -> URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            return nil
        }
        return url
    }
}

// MARK: - Store

@MainActor
final class SettingsStore: ObservableObject {
    @Published var personality: PersonalityProfile?
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
        connectors = sync.connectors
        health = sync.health
        isLoading = false
    }
}

// MARK: - Personality detail (read-only; edits via inbox)

struct PersonalityDetailView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        List {
            if let p = store.personality {
                Section("Identity") {
                    LabeledContent("Name", value: p.name)
                    LabeledContent("Kind", value: p.personaKind)
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

struct TraitRow: View {
    let label: String
    let value: Double

    var body: some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            // One identity tint for every trait: the value is information,
            // the color is not. Traffic-light tints made low traits (a
            // personality fact) read as warnings (a health problem).
            ProgressView(value: value)
                .tint(NativeAgentPalette.agentAccent)
            Text(String(format: "%.0f%%", value * 100))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(Int((value * 100).rounded())) percent")
    }
}

// MARK: - Trust policy

struct TrustPolicyView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        List {
            if let policy = store.trustPolicy {
                Section("Permission Level") {
                    LabeledContent("Level", value: policy.permissionLevel ?? "—")
                    LabeledContent("Autonomy Default", value: policy.autonomyDefault ?? "—")
                    if let outside = policy.effectiveOutsideDefault {
                        LabeledContent("Outside Default", value: outside)
                    }
                    LabeledContent("Developer Mode", value: policy.developerMode == true ? "On" : "Off")
                    LabeledContent("Require Backups", value: policy.effectiveRequireBackups == true ? "Yes" : "No")
                }
                if let workshop = policy.workshopPolicy {
                    Section("Workshop Policy") {
                        LabeledContent("Workshop Enabled", value: workshop.enabled == true ? "Yes" : "No")
                        LabeledContent("Show Timeline", value: workshop.showTimeline == true ? "Yes" : "No")
                    }
                }
                if let training = policy.trainingPolicy {
                    Section("Training Policy") {
                        LabeledContent("Autonomous Training", value: training.autonomousTraining == true ? "On" : "Off")
                        LabeledContent("Dream Scheduler", value: training.dreamScheduler == true ? "On" : "Off")
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

struct ConnectorsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        List {
            if store.connectors.isEmpty {
                AppEmptyState(
                    title: "No connectors",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: "Connector status will appear after iCloud sync."
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(store.connectors) { connector in
                    GlassCard(tint: connector.enabled == true ? NativeAgentPalette.agentAccent : .secondary, cornerRadius: 14) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(connector.name).font(AppFont.section)
                                if let kind = connector.kind { Text(kind).font(AppFont.label).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            PulsingDot(color: connector.enabled == true ? .green : .secondary)
                            Text(connector.healthStatus ?? (connector.enabled == true ? "Enabled" : "Disabled"))
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
