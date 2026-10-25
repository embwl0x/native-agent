import EngineRuntime
import SwiftUI
import NativeAgentShared
import PersistenceCore
import ChromeControl
import TrustCenter

// Blueprint: | `TrustPermissionsViews.swift` | Trust permission views: checked Chrome/multimodal/training/Workshop/memory policy controls through existing Trust owners |

struct ChromeControlPermissionsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var enabled = false
    @State private var isSaving = false
    @State private var chromeSetupMessage: String?
    @State private var connectionState: ChromeControlConnectionState = .extensionNotLoaded

    private var fullMacActive: Bool {
        appModel.engine.trust.policy.map(TrustAccessModeCapabilityCatalog.fullMacGrantIsActive) ?? false
    }

    private var isOn: Bool { enabled || fullMacActive }

    /// The row's one status line: permission, then connection, each said
    /// once. Full Mac and the switch both read "Allowed"; the switch (or the
    /// Full Mac tooltip) says where the permission comes from.
    private var statusText: String {
        guard isOn else { return "Not allowed" }
        switch connectionState {
        case .connected: return "Allowed · connected"
        case .disconnected: return "Allowed · extension not connected"
        case .extensionNotLoaded: return "Allowed · extension not set up"
        }
    }

    /// Two rows for Trust's group card (Alive glass): the switch with its
    /// state, then the setup — folded away once Chrome is connected.
    var body: some View {
        Group {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Chrome control")
                        .font(ShellType.rowTitle)
                        .foregroundStyle(NativeAgentShell.text)
                    Text("I use Chrome while you are signed in. I can open background tabs or work in a selected tab. I stop using a tab when you interact with it and check this permission before every action.")
                        .font(ShellType.rowDetail)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                AlivePill(statusText)
                    .accessibilityIdentifier("trust.chrome.status")
                    // Full Mac holds this on, so there is no switch (a disabled
                    // one read as off); the tooltip says where "Allowed" comes from.
                    .help(fullMacActive
                        ? "Full Mac allows Chrome control. In narrower modes this is a switch. The Chrome extension must still be installed."
                        : "")
                if !fullMacActive {
                    Toggle("Chrome control", isOn: Binding(
                        get: { isOn },
                        set: { newValue in
                            enabled = newValue
                            Task {
                                isSaving = true
                                await appModel.saveChromeControlEnabled(newValue)
                                isSaving = false
                                syncFromPolicy()
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .hazeTinted()
                    .disabled(isSaving)
                    .help("The Chrome extension must still be installed.")
                }
            }
            .task {
                syncFromPolicy()
                for await state in await appModel.engine.chrome.connectionStates() {
                    connectionState = state
                }
            }
            .onChange(of: appModel.engine.trust.policy) { _, _ in
                if !isSaving { syncFromPolicy() }
            }

            if isOn && connectionState == .connected {
                DisclosureGroup("How to set up again") {
                    setupSteps.padding(.top, 8)
                }
                .font(ShellType.label)
            } else {
                setupSteps
            }
        }
    }

    private var setupSteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Set up Chrome", systemImage: "arrow.up.forward.app") {
                setUpChrome()
            }
            .accessibilityIdentifier("trust.chrome.setup")
            Text("I'll open Chrome and load my extension. Allow Mac access if asked, then watch me set it up.")
                .font(ShellType.rowDetail)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("Set up once on each Mac. Updates happen automatically.")
                .font(ShellType.rowDetail)
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let chromeSetupMessage {
                Text(chromeSetupMessage)
                    .font(ShellType.rowDetail)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isSaving {
                ProgressView("Updating Chrome control…")
                    .controlSize(.small)
            }
        }
    }

    private func syncFromPolicy() {
        enabled = appModel.engine.trust.policy?.chromeControlPolicy?.enabled ?? false
    }

    private func setUpChrome() {
        Task {
            do {
                _ = try await ChromeExtensionFolder.setUp()
                chromeSetupMessage = "Chrome connected."
            } catch { chromeSetupMessage = ChromeExtensionFolder.setupMessage(error) }
        }
    }
}

// PATCH-2026-05-06: multimodal-ui Sprint 3 — multimodal permission toggles.
struct MultimodalPermissionsView: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage("voiceAutoRead") private var voiceAutoRead = false
    @State private var draftPolicy: TrustMultimodalPolicy?
    @State private var isSaving = false

    /// Alive glass (2026-09-23): one group card of switch rows. Every change
    /// here applies at once; Trust's feature footnote says so.
    var body: some View {
        AliveGroupCard {
            FeatureSwitchRow(
                title: "Allow screen capture",
                detail: "I capture your screen when you click the camera button in Chat.",
                isOn: policyBinding(\.screen_capture)
            )
            .disabled(isSaving || draftPolicy == nil)
            FeatureSwitchRow(
                title: "Allow image understanding",
                detail: "I send images you attach to your AI provider so I can read them. This counts toward your subscription usage.",
                isOn: policyBinding(\.vision_api_calls)
            )
            .disabled(isSaving || draftPolicy == nil)
            FeatureSwitchRow(
                title: "Allow reading PDFs",
                detail: "I read the text of a PDF you attach into the conversation. With this off, I skip the attachment and I'm told I did, so I never guess at what it says. A PDF that is only pictures of pages has no text to read.",
                isOn: policyBinding(\.file_ingestion_pdf)
            )
            .disabled(isSaving || draftPolicy == nil)
            FeatureSwitchRow(
                title: "Allow image generation",
                detail: "I make images when you ask for one.",
                isOn: policyBinding(\.image_generation_openai)
            )
            .disabled(isSaving || draftPolicy == nil)
            if draftPolicy == nil {
                FeatureNote("Permissions unavailable. Reload Trust to check your saved settings.")
            }
            FeatureSwitchRow(
                title: "Read replies aloud automatically",
                detail: "I read new replies aloud with your saved voice settings. The OpenAI voice needs its own permission.",
                identifier: "trust.multimodal.voice-output.auto-read",
                isOn: $voiceAutoRead
            )
        }
        .task { syncDraftPolicy() }
        .onChange(of: appModel.engine.trust.policy) { _, _ in
            if !isSaving { syncDraftPolicy() }
        }
    }

    private func policyBinding(_ keyPath: WritableKeyPath<TrustMultimodalPolicy, Bool>) -> Binding<Bool> {
        Binding(
            get: { draftPolicy?[keyPath: keyPath] ?? false },
            set: { newValue in savePolicy(keyPath, value: newValue) }
        )
    }

    private func savePolicy(_ keyPath: WritableKeyPath<TrustMultimodalPolicy, Bool>, value: Bool) {
        guard !isSaving, var next = draftPolicy else { return }
        next[keyPath: keyPath] = value
        draftPolicy = next
        isSaving = true
        Task {
            _ = await appModel.saveMultimodalPolicy(next)
            isSaving = false
            syncDraftPolicy()
        }
    }

    private func syncDraftPolicy() {
        draftPolicy = appModel.engine.trust.policy?.multimodalPolicy
    }
}

// Permissions for unattended background work.
struct TrainingPermissionsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var isSaving = false

    private var verdict: TrustFacade.FeatureVerdict? { appModel.engine.trust.unattendedWork }
    private var unattendedForced: Bool { verdict?.forced == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            AliveGroupCard {
                // Sweep R4 C9 — COPY ONLY. "improvement kernel" named an
                // internal component, not a thing the user grants.
                FeatureSwitchRow(
                    title: "Let me work unattended",
                    detail: unattendedForced
                        ? "Full Mac access keeps me working unattended: helpers on their schedules, background improvement. Choosing Safe on the Access tab turns it off. Work mode and Builder keep it on but unlock this switch, so you can turn it off here. Run once still works either way, because that is you asking."
                        : "The main switch for background work: helpers on their schedules and replies to events, the weekly improvement pass. Run once still works either way, because that is you asking. Even with this on, I can only change my own files inside NativeAgent, never the rest of your Mac.",
                    isOn: Binding(
                        get: { verdict?.enabled == true },
                        set: { newValue in
                            guard !unattendedForced else { return }
                            Task { await saveEnableAutonomy(newValue) }
                        }
                    )
                )
                .disabled(isSaving || unattendedForced || verdict == nil)
                if verdict == nil {
                    FeatureNote("Permissions unavailable. Reload Trust to check your saved settings.")
                }
            }
        }
    }

    private func saveEnableAutonomy(_ enabled: Bool) async {
        isSaving = true
        await appModel.saveEnableAutonomy(enabled)
        isSaving = false
    }
}

// PATCH-2026-05-07: executions-b Permissions panel for autonomous executions
struct WorkshopPermissionsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var isSaving = false

    private var verdict: TrustFacade.FeatureVerdict? { appModel.engine.trust.deskTasks }
    private var deskTasksForced: Bool { verdict?.forced == true }

    /// Alive glass (2026-09-23): one group card of switch rows.
    var body: some View {
        AliveGroupCard {
            FeatureSwitchRow(
                title: "Allow Desk tasks",
                detail: deskTasksForced
                    ? "Developer mode allows Desk tasks, including in Full Mac."
                    : "I create Desk tasks and plan them in several steps.",
                isOn: Binding(
                    get: { verdict?.enabled == true },
                    set: { newValue in
                        Task { await saveWorkshopPolicy(enabled: newValue) }
                    }
                )
            )
            .disabled(isSaving || deskTasksForced || verdict == nil)
            if verdict == nil {
                FeatureNote("Permissions unavailable. Reload Trust to check your saved settings.")
            }
            FeatureNote("Desk tasks follow the same approval rules as the rest of my tools. In Full Mac, allowed actions run without asking you again; narrower modes may ask before I send or delete anything.")
        }
    }

    private func saveWorkshopPolicy(enabled: Bool) async {
        isSaving = true
        await appModel.saveWorkshopPolicyToggle(enabled: enabled)
        isSaving = false
    }
}

// PATCH-2026-05-07: living-memory Permissions panel for living memory system
struct LivingMemoryPermissionsView: View {
    @Environment(AppModel.self) private var appModel
    private var policy: TrustMemoryPolicy? { appModel.engine.trust.memoryPermissions }
    @State private var isSaving = false

    private var pendingCount: Int {
        appModel.engine.memory.proposals.filter { $0.status == "pending" }.count
    }

    /// Alive glass (2026-09-23): one group card of switch rows. Titles match
    /// the same switches on Setup (SetupFeatureRows.swift).
    var body: some View {
        AliveGroupCard(waiting: pendingCount > 0) {
            FeatureSwitchRow(
                title: "Remember across conversations",
                detail: "Each time you write, I look through all our past conversations for what is relevant. Read only; on by default.",
                isOn: Binding(
                    get: { policy?.cross_session_recall == true },
                    set: { v in
                        guard var next = policy else { return }
                        next.cross_session_recall = v
                        Task { await saveMemoryPolicy(next) }
                    }
                )
            )
            FeatureSwitchRow(
                title: "Nightly memory consolidation",
                detail: MemoryPolicyHelpCopy.nightlyConsolidation,
                isOn: Binding(
                    get: { policy?.consolidation_enabled == true },
                    set: { v in
                        guard var next = policy else { return }
                        next.consolidation_enabled = v
                        Task { await saveMemoryPolicy(next) }
                    }
                )
            )
            FeatureSwitchRow(
                title: "Knowledge graph",
                detail: "I join up the people, places and things your conversations keep mentioning, and draw them in Memory → Graph.",
                isOn: Binding(
                    get: { policy?.knowledge_graph_enabled == true },
                    set: { v in
                        Task { await patchMemoryPolicy(knowledgeGraph: v) }
                    }
                )
            )
            FeatureSwitchRow(
                title: "Recurring memories are proposed as facts",
                detail: "When something useful keeps coming back, I suggest keeping it as a lasting fact, without loading all my memory into every reply.",
                isOn: Binding(
                    get: { policy?.adaptive_promotion == true },
                    set: { v in
                        Task { await patchMemoryPolicy(adaptivePromotion: v) }
                    }
                )
            )
            FeatureSwitchRow(
                title: "Memory hygiene",
                detail: "I regularly clear out old, noisy, duplicate and low-value memories so they don't pile up.",
                isOn: Binding(
                    get: { policy?.hygiene_enabled == true },
                    set: { v in
                        Task { await patchMemoryPolicy(hygiene: v) }
                    }
                )
            )
            if policy == nil {
                FeatureNote("Permissions unavailable. Reload Trust to check your saved settings.")
            }
            if pendingCount > 0 {
                HStack(spacing: 8) {
                    AliveWaitingDot()
                    Text("\(pendingCount) memory suggestion\(pendingCount == 1 ? "" : "s") waiting for you in Memory")
                        .font(ShellType.labelMedium)
                        .foregroundStyle(NativeAgentShell.text)
                }
            }
            // Sweep R4 C9 — COPY ONLY. "harness and promotion proposals"
            // named machinery; the user is being told which page to look on.
            FeatureNote("What I remember, how I recall it, and how I tidy myself up are all set here. Suggested memory changes wait for you in Memory; suggested changes to how I behave wait in Self-Improvement.")
        }
        .disabled(isSaving || policy == nil)
    }

    private func saveMemoryPolicy(_ policy: TrustMemoryPolicy) async {
        isSaving = true
        await appModel.saveMemoryPolicy(
            consolidationEnabled: policy.consolidation_enabled,
            crossSessionRecall: policy.cross_session_recall
        )
        isSaving = false
    }

    private func patchMemoryPolicy(knowledgeGraph: Bool? = nil, adaptivePromotion: Bool? = nil, hygiene: Bool? = nil) async {
        isSaving = true
        await appModel.patchMemoryPolicy(
            knowledgeGraphEnabled: knowledgeGraph,
            adaptivePromotion: adaptivePromotion,
            hygieneEnabled: hygiene
        )
        isSaving = false
    }
}

/// A switch row on Trust's feature cards (Alive glass): the words on the
/// left, the haze switch on the right. Same shape as the Mac control rows.
private struct FeatureSwitchRow: View {
    let title: String
    var detail: String? = nil
    var identifier: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(ShellType.rowTitle)
                    .foregroundStyle(NativeAgentShell.text)
                if let detail {
                    Text(detail)
                        .font(ShellType.rowDetail)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .hazeTinted()
                .accessibilityIdentifier(identifier ?? "")
        }
    }
}

/// A quiet line of explanation inside a feature card.
private struct FeatureNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(ShellType.rowDetail)
            .foregroundStyle(NativeAgentShell.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct TrustBoundaryRow: View {
    var title: String
    var detail: String
    var systemImage: String
    var tone: TrustSafetyBoundaryTone = .neutral

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 22)
            // The privacy map's row type, so the two Advanced cards read at
            // one size.
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                Text(detail)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
    }

    private var tint: Color {
        switch tone {
        case .neutral:
            .secondary
        case .caution:
            .orange
        case .danger:
            .red
        case .unavailable:
            .orange
        }
    }
}

// MARK: - Plain-English memory policy help copy
//
// UI-6 (2026-08-01, public era): these tooltips named USER.md, a file a public
// user never opens and has no reason to know about. They describe the same
// thing the Memory page calls a long-term memory profile. Pure values so the
// wording is pinnable in PublicHonestyCopyTests.
enum MemoryPolicyHelpCopy {
    static let nightlyConsolidation =
        "Once a week, I look for things that keep coming up in your conversations and suggest them for your long-term memory profile."
}
