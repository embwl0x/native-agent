import SwiftUI
import NativeAgentShared
// Blueprint: | `AdvancedView.swift` | More navigation reads the pairing-owned surface layout and composes Status and Runs |

enum MoreAboutPresentation {
    static let text = "Some advanced controls require a live Mac connection. Skill installs, eval runs, and Desk policy editing are Mac-only today. Desk changes sync with the paired Mac."
}

// MARK: - AdvancedView (hidden behind "More" tab)

struct AdvancedView: View {
    @Binding var deskTaskNavigationTarget: NativeAgentNotificationLaunchIntent?

    init(deskTaskNavigationTarget: Binding<NativeAgentNotificationLaunchIntent?> = .constant(nil)) {
        _deskTaskNavigationTarget = deskTaskNavigationTarget
    }
    @EnvironmentObject private var pairingStore: PairingStore
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @StateObject private var store = AdvancedStore()
    @State private var showPairingRecovery = false
    @State private var showDesignScreen = MobileDesignSamples.screen != nil
    private let sync = iCloudSyncEngine.shared
    #if DEBUG
    @StateObject private var designApprovals = ApprovalsStore()
    @StateObject private var designInbox = InboxStore()
    #endif

    var body: some View {
        NavigationStack {
            AlivePage(title: "More", line: "Rooms, settings and tools.", style: .root) {
                if !bridgeClient.connection.holds {
                    AliveSection("Connection", surface: .none) {
                        AliveCalmState(title: AliveConnection.line(bridgeClient.connection),
                                       line: bridgeClient.connection.headline.lever
                                        ?? "Open Settings to repair this iPhone’s connection, or pair with your Mac again.",
                                       actionTitle: "Pair with Mac",
                                       actionHint: "Opens pairing so this iPhone can reconnect to the Mac.") {
                            showPairingRecovery = true
                        }
                    }
                }

                // More's sections in the layout's order, as the phone's
                // profile shows them.
                let layout = sync.surfaceLayout ?? SurfaceLayout.seed(from: "", at: "")
                ForEach(layout.shown("more", profile: layout.phone).map(\.name), id: \.self) { block in
                    switch block {
                    case "rooms":
                        AliveSection("Rooms") {
                            link("Scheduler", "Things set to happen later") { MobileSchedulerView() }
                            AliveDivider()
                            link("Helpers", "Run and manage helpers") { MobileHelpersView() }
                            AliveDivider()
                            link("Agents", "Conversations with other agents") { MobileAgentsView() }
                            AliveDivider()
                            link("Desk tasks", "Work I'm doing for you") {
                                WorkshopView()
                            }
                            AliveDivider()
                            link("Skills & Tools", "What I know how to do") {
                                SkillsToolsView()
                            }
                            AliveDivider()
                            link("Personality", "How I think and sound") { PersonalityDetailView() }
                            AliveDivider()
                            link("Connectors", "The services I can reach") { ConnectorsView() }
                            AliveDivider()
                            link("Trust", "What I may do on my own") { TrustPolicyView() }
                        }
                    case "setup":
                        // One door: Telegram, Providers and every Mac setting
                        // (Mac Integration among them) are inside it.
                        AliveSection("Setup") {
                            link("Settings", "This iPhone, the Mac link and every Mac setting") { SettingsViewFull() }
                        }
                    case "power":
                        // Opt-in deep surfaces and diagnostics: lower and quieter.
                        AliveSection("Power user", footer: MoreAboutPresentation.text) {
                            quietLink("Knowledge Graph") { KnowledgeGraphView() }
                            AliveDivider()
                            quietLink("Turn Inspector") { TurnInspectorView() }
                            AliveDivider()
                            quietLink("Mac Tools") { MacToolsView() }
                            AliveDivider()
                            quietLink("Status") { StatusDetailView(store: store) }
                            AliveDivider()
                            quietLink("Runs Log") { RunsLogView(store: store) }
                        }
                        .padding(.top, 12)
                    default:
                        EmptyView()
                    }
                }
            }
            .navigationDestination(item: $deskTaskNavigationTarget) { intent in
                WorkshopView(notifiedTaskID: intent.taskID)
                    .id(intent.id)
            }
            #if DEBUG
            .navigationDestination(isPresented: $showDesignScreen) {
                designDestination
                    .allowsHitTesting(false)
            }
            #endif
            .sheet(isPresented: $showPairingRecovery) {
                PairingView(onSkip: {
                    showPairingRecovery = false
                }, onPaired: {
                    bridgeClient.recordMacConfirmation()
                    showPairingRecovery = false
                })
                .environmentObject(pairingStore)
            }
        }
        .macSyncErrorBanner()
    }

    private func link<Destination: View>(_ title: String, _ detail: String,
                                         @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            AliveRow(title, detail: detail) { AliveChevron() }
        }
        .aliveRowButtonStyle()
    }

    private func quietLink<Destination: View>(_ title: String,
                                              @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            AliveRow(title) { AliveChevron() }
        }
        .aliveRowButtonStyle()
    }

    @ViewBuilder
    private var designDestination: some View {
        #if DEBUG
        switch MobileDesignSamples.screen {
        case "settings": SettingsViewFull()
        case "providers": ProviderSettingsView()
        case "pairing": PairingView()
        case "approvals": ApprovalsView().environmentObject(designApprovals)
        case "inbox": InboxView(embedInNavigationStack: false).environmentObject(designInbox)
        case "autonomy": AutonomyView()
        case "mac-tools": MacToolsView()
        case "skills": SkillsToolsView()
        case "graph": KnowledgeGraphView()
        case "turns": TurnInspectorView()
        case "workshop": WorkshopView()
        case "desk": MobileDeskView()
        case "status": StatusDetailView(store: store)
        case "runs": RunsLogView(store: store)
        case "personality": PersonalityDetailView(store: Self.sampleSettingsStore())
        case "trust": TrustPolicyView(store: Self.sampleSettingsStore())
        case "connectors": ConnectorsView(store: Self.sampleSettingsStore())
        case "trust-empty": TrustPolicyView(store: SettingsStore())
        case "toast":
            VStack(spacing: 0) {
                MacSnapshotFreshnessBadge(lastSyncedAt: nil)
                Spacer()
            }
            .mobileReadingScreen()
            .navigationTitle("Connection updates")
            .onAppear { SystemToastCenter.shared.push(info: "The latest project summary is available on the Mac.") }
        default: EmptyView()
        }
        #endif
    }

    #if DEBUG
    /// Process-local screenshot data for the Personality, Trust and Connectors rooms.
    private static func sampleSettingsStore() -> SettingsStore {
        let personality = PersonalityProfile(
            name: "Sample", personaKind: "Companion",
            essence: "A steady, curious presence that keeps the day simple and the next step clear.",
            voice: "Plain and warm. Short sentences, one idea at a time, no filler.",
            traits: PersonalityTraits(warmth: 0.8, directness: 0.7, humor: 0.45, proactivity: 0.6,
                                      rigor: 0.75, autonomy: 0.55, creativity: 0.65, brevity: 0.7))
        let store = SettingsStore(sync: iCloudSyncEngine(personality: personality))
        store.sync.trustPolicy = TrustPolicy(
            permissionLevel: "Standard", autonomyDefault: "Ask first", requireBackups: true,
            outsideDefault: "Read only", developerMode: false,
            workshopPolicy: TrustWorkshopPolicy(enabled: true),
            trainingPolicy: TrustTrainingPolicy(dreamScheduler: true))
        store.sync.connectors = [
            MobileConnectorSnapshot(id: "slack", name: "Slack", kind: "Messaging", enabled: true, healthStatus: "connected"),
        ]
        return store
    }
    #endif
}
