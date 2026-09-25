import SwiftUI
import AppKit
import CoreGraphics
import ScreenCaptureKit
import ScreenVision
import Speech
import AVFoundation
import UniformTypeIdentifiers
import NativeAgentShared
import MemoryV2
import PersistenceCore
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
#endif

struct ChromeControlPermissionsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var enabled = false
    @State private var isSaving = false
    @State private var chromeSetupMessage: String?
    @State private var connectionState: ChromeControlConnectionState = .extensionNotLoaded

    private var fullMacActive: Bool {
        appModel.trustPolicy.map(AppModel.fullMacGrantIsActive) ?? false
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
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(NativeAgentShell.text)
                    Text("I use Chrome while you are signed in. I can open background tabs or work in a selected tab. I stop using a tab when you interact with it and check this permission before every action.")
                        .font(.system(size: 12))
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
                for await state in await ChromeControlRuntime.shared.connectionStates() {
                    connectionState = state
                }
            }
            .onChange(of: appModel.trustPolicy) { _, _ in
                if !isSaving { syncFromPolicy() }
            }

            if isOn && connectionState == .connected {
                DisclosureGroup("How to set up again") {
                    setupSteps.padding(.top, 8)
                }
                .font(.system(size: 13))
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
            Text("Set up Chrome puts the extension in your home folder, shows it in Finder and opens Chrome's extensions page. Then:\n1. On that page, turn on Chrome's Developer mode (top right).\n2. Click Load unpacked.\n3. Choose the \"\(ChromeExtensionFolder.visible.lastPathComponent)\" folder in your home folder, or drag it from Finder onto the page.")
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("I set up my part automatically. The extension is a separate step on each Mac and does not sync with your Google account. The purple NativeAgent tab group can sync even when the extension is missing.")
                .font(.system(size: 12))
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let chromeSetupMessage {
                Text(chromeSetupMessage)
                    .font(.system(size: 12))
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
        enabled = appModel.trustPolicy?.chromeControlPolicy?.enabled ?? false
    }

    private func setUpChrome() {
        Task {
            chromeSetupMessage = await ChromeExtensionFolder.setUp().message
        }
    }
}

// PATCH-2026-05-06: multimodal-ui Sprint 3 — multimodal permission toggles.
struct MultimodalPermissionsView: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage("voiceAutoRead") private var voiceAutoRead = false
    @State private var draftPolicy = TrustMultimodalPolicy()
    @State private var isSaving = false

    private var currentPolicy: TrustMultimodalPolicy {
        draftPolicy
    }

    /// Alive glass (2026-09-23): one group card of switch rows. Every change
    /// here applies at once; Trust's feature footnote says so.
    var body: some View {
        AliveGroupCard {
            FeatureSwitchRow(
                title: "Allow screen capture",
                detail: "I capture your screen when you click the camera button in Chat.",
                isOn: policyBinding(\.screen_capture)
            )
            FeatureSwitchRow(
                title: "Allow image understanding",
                detail: "I send images you attach to your AI provider so I can read them. This counts toward your subscription usage.",
                isOn: policyBinding(\.vision_api_calls)
            )
            FeatureSwitchRow(
                title: "Allow reading PDFs",
                detail: "I read the text of a PDF you attach into the conversation. With this off, I skip the attachment and I'm told I did, so I never guess at what it says. A PDF that is only pictures of pages has no text to read.",
                isOn: policyBinding(\.file_ingestion_pdf)
            )
            FeatureSwitchRow(
                title: "Allow image generation",
                detail: "I make images when you ask for one.",
                isOn: policyBinding(\.image_generation_openai)
            )
            FeatureSwitchRow(
                title: "Read replies aloud automatically",
                detail: "I read new replies aloud with your saved voice settings. The OpenAI voice needs its own permission.",
                identifier: "trust.multimodal.voice-output.auto-read",
                isOn: $voiceAutoRead
            )
        }
        .task { syncDraftPolicy() }
        .onChange(of: appModel.trustPolicy) { _, _ in
            if !isSaving { syncDraftPolicy() }
        }
    }

    private func policyBinding(_ keyPath: WritableKeyPath<TrustMultimodalPolicy, Bool>) -> Binding<Bool> {
        Binding(
            get: { currentPolicy[keyPath: keyPath] },
            set: { newValue in savePolicy(keyPath, value: newValue) }
        )
    }

    private func savePolicy(_ keyPath: WritableKeyPath<TrustMultimodalPolicy, Bool>, value: Bool) {
        var next = draftPolicy
        next[keyPath: keyPath] = value
        draftPolicy = next
        Task {
            isSaving = true
            _ = await appModel.saveMultimodalPolicy(next)
            isSaving = false
            syncDraftPolicy()
        }
    }

    private func syncDraftPolicy() {
        if let policy = appModel.trustPolicy?.multimodalPolicy {
            draftPolicy = policy
        }
    }
}

// PATCH-2026-05-07: training-b1 ui Permissions panel for autonomous training loop.
struct TrainingPermissionsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var draftEnableAutonomy = false
    /// Full Mac (or checked Full Mac YOLO) admits unattended work whatever
    /// `enableAutonomy` says — including an upgraded policy that never carried
    /// the key. The switch shows the EFFECTIVE state, so it can never read OFF
    /// while `BackgroundLoopsAssembly.unattendedWorkAllowed` is admitting work.
    @State private var unattendedForced = false
    @State private var draftTraining = TrustTrainingPolicy()
    @State private var draftPromotion = TrustPromotionPolicy()
    @State private var isSaving = false
    /// The EFFECTIVE dream gate (dream_scheduler AND dream_cycle_enabled), read
    /// through the same composite the Dreams page and Setup read. `trustPolicy`
    /// carries no personalityPolicy block, so it cannot come from the drafts.
    @State private var draftDreamComposite = false
    @State private var completedInitialRead = false
    @State private var loadedPolicy: TrustPolicy?
    @State private var dreamReadGate = LatestAsyncRequestGate()
    @State private var unattendedReadGate = LatestAsyncRequestGate()

    /// Alive glass (2026-09-23): the master switch in its own group card, then
    /// practice runs and automatic review as their own eyebrow and card. No
    /// per-row timing pills; Trust's feature footnote says when changes land.
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            AliveGroupCard {
                // Sweep R4 C9 — COPY ONLY. "improvement kernel" named an
                // internal component, not a thing the user grants.
                FeatureSwitchRow(
                    title: "Let me work unattended",
                    detail: unattendedForced
                        ? "Full Mac access lets me work unattended: bots on their schedules, practice runs and background improvement. Changing the access mode above is how to turn it off. Run once is you asking, so it works either way."
                        : "The main switch for background work: scheduled bots and replies to events, practice runs and app improvements. Run once is you asking, so it works either way. Even with this on, I can only change my own files inside NativeAgent, never the rest of your Mac.",
                    isOn: Binding(
                        get: { draftEnableAutonomy || unattendedForced },
                        set: { newValue in
                            guard !unattendedForced else { return }
                            draftEnableAutonomy = newValue
                            Task { await saveEnableAutonomy(newValue) }
                        }
                    )
                )
                .disabled(unattendedForced)
            }
            // Taste pass 2026-07-24: was "Autonomous Training", an exact echo
            // of the card title directly above it.
            featureSection("Practice runs") {
                FeatureSwitchRow(
                    title: "Let me practice on my own",
                    detail: "I work through my own saved exercises in the background, notice where my answers have slipped, and write up suggested changes. I never apply a change on my own; every suggestion waits for you.",
                    isOn: Binding(
                        get: { draftTraining.autonomous_training },
                        set: { newValue in
                            var next = draftTraining
                            next.autonomous_training = newValue
                            if !newValue {
                                next.dream_scheduler = false
                                next.route_through_promotion = false
                            }
                            draftTraining = next
                            Task { await saveAll(training: next, promotion: draftPromotion) }
                        }
                    )
                )
                // Sweep R4 C9 — COPY ONLY. The detail was a raw endpoint path
                // for a daemon that no longer exists (README "What exists
                // today": the Swift app owns the runtime in-process).
                FeatureSwitchRow(
                    title: "Run dream cycle nightly",
                    detail: "Once a night at 3:30 AM I look back over recent conversations and what I learned that day, write it up as a dated diary entry, and leave you a short digest in the morning. Needs practice runs turned on above.",
                    isOn: Binding(
                        // 2026-09-06: this read and wrote trainingPolicy
                        // .dream_scheduler alone, while the runtime requires
                        // dream_scheduler AND personalityPolicy
                        // .dream_cycle_enabled (DreamREMGatePolicy.dreamEnabled)
                        // and Setup's "Dreams at night" row moves both. Turning
                        // dreams off in Setup therefore left this switch showing
                        // ON with dreams dead. Both controls now show and set
                        // the EFFECTIVE gate, through the same composite write.
                        get: { draftDreamComposite },
                        set: { newValue in
                            draftDreamComposite = newValue  // optimistic — no snap-back
                            Task { await saveDreamCycle(newValue) }
                        }
                    )
                )
                .disabled(!draftTraining.autonomous_training)
            }

            // PATCH-2026-05-07: self-improvement-ui Promotion engine trust toggles
            // Sweep R4 C9 — COPY ONLY. "Promotion engine" was the internal
            // component name; what the user is granting is an automatic
            // check that a proposed change is good enough to keep.
            featureSection("Automatic review") {
                // Sweep R4 C9 — COPY ONLY. The detail was a raw endpoint path
                // plus "harness eval", neither of which appears anywhere else
                // in the UI.
                FeatureSwitchRow(
                    title: "Check proposed changes automatically",
                    detail: "Before any suggested change is kept, I re-run my own test set against it. A change that scores worse than what it replaces is thrown away instead of applied.",
                    isOn: Binding(
                        get: { draftPromotion.enabled },
                        set: { newValue in
                            var next = draftPromotion
                            next.enabled = newValue
                            if !newValue {
                                next.auto_promote_tier_a = false
                                var training = draftTraining
                                training.route_through_promotion = false
                                draftTraining = training
                                draftPromotion = next
                                Task { await saveAll(training: training, promotion: next) }
                            } else {
                                draftPromotion = next
                                Task { await saveAll(training: draftTraining, promotion: next) }
                            }
                        }
                    )
                )
                // Sweep R4 C9 — COPY ONLY. "Tier A acts as Tier B" was the
                // only place those tiers were ever named; nothing in the UI
                // defined either one.
                FeatureSwitchRow(
                    title: "Keep low-risk changes without asking you",
                    detail: "Low-risk means my own notes about how I should behave and the exercises I practice against, never your files or your settings. With this off, every change waits for your sign-off, however small. Turn it on only if you trust the automatic check above to catch a bad one.",
                    isOn: Binding(
                        get: { draftPromotion.auto_promote_tier_a },
                        set: { newValue in
                            var next = draftPromotion
                            next.enabled = true
                            next.auto_promote_tier_a = newValue
                            draftPromotion = next
                            Task { await saveAll(training: draftTraining, promotion: next) }
                        }
                    )
                )
                .disabled(!draftPromotion.enabled)
                FeatureSwitchRow(
                    title: "Put practice suggestions through the automatic check too",
                    detail: "A suggestion you approve is still tested before it is written, instead of being applied straight away. Needs both practice runs and automatic review turned on.",
                    isOn: Binding(
                        get: { draftTraining.route_through_promotion },
                        set: { newValue in
                            var training = draftTraining
                            training.autonomous_training = true
                            training.route_through_promotion = newValue
                            var promotion = draftPromotion
                            promotion.enabled = true
                            draftTraining = training
                            draftPromotion = promotion
                            Task { await saveAll(training: training, promotion: promotion) }
                        }
                    )
                )
                .disabled(!draftPromotion.enabled || !draftTraining.autonomous_training)
                FeatureNote("Practice only ever suggests. Changes to my personality and voice never apply without your approval.")
            }
        }
        .task(id: appModel.trustPolicy) {
            let policy = appModel.trustPolicy
            guard !completedInitialRead || loadedPolicy != policy else { return }
            if !isSaving {
                syncDraftsFromPolicy()
                await refreshDreamComposite()
            }
            guard !Task.isCancelled else { return }
            await refreshUnattended()
            guard !Task.isCancelled else { return }
            loadedPolicy = policy
            completedInitialRead = true
        }
        .onDisappear {
            _ = dreamReadGate.begin()
            _ = unattendedReadGate.begin()
        }
    }

    private func featureSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
            AliveEyebrow(title)
            AliveGroupCard { content() }
        }
        .accessibilityElement(children: .contain)
    }

    /// The one gate every unattended lane asks, minus the raw toggle: what is
    /// left is the access mode admitting work the toggle's own value denies.
    private func refreshUnattended() async {
        let request = unattendedReadGate.begin()
        let root = appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let allowed = await BackgroundLoopsAssembly.unattendedWorkAllowed(dataRoot: root)
        guard !Task.isCancelled, unattendedReadGate.accepts(request) else { return }
        unattendedForced = allowed && !(appModel.trustPolicy?.enableAutonomy ?? false)
    }

    private func refreshDreamComposite() async {
        let request = dreamReadGate.begin()
        let enabled = await appModel.client.swiftDreamCompositeEnabled()
        guard !Task.isCancelled, dreamReadGate.accepts(request) else { return }
        draftDreamComposite = enabled
    }

    /// One call: the two gates move together, and this is the same composite
    /// write the Dreams page and Setup's "Dreams at night" row make.
    private func saveDreamCycle(_ enabled: Bool) async {
        isSaving = true
        _ = await appModel.setDreamCycleEnabled(enabled)
        isSaving = false
        syncDraftsFromPolicy()
        await refreshDreamComposite()
    }

    private func syncDraftsFromPolicy() {
        if let trustPolicy = appModel.trustPolicy {
            draftEnableAutonomy = trustPolicy.enableAutonomy
        } else if let summary = appModel.improvementSummary {
            draftEnableAutonomy = summary.trustEnabled ?? summary.enabled
        }
        draftTraining = appModel.trustPolicy?.trainingPolicy ?? TrustTrainingPolicy()
        draftPromotion = appModel.trustPolicy?.promotionPolicy ?? TrustPromotionPolicy()
    }

    private func saveEnableAutonomy(_ enabled: Bool) async {
        isSaving = true
        await appModel.saveEnableAutonomy(enabled)
        isSaving = false
        syncDraftsFromPolicy()
    }

    private func saveAll(training: TrustTrainingPolicy, promotion: TrustPromotionPolicy) async {
        guard let policy = appModel.trustPolicy else { return }
        isSaving = true
        await appModel.saveTrustPolicyWithPromotion(
            permissionLevel: policy.permissionLevel,
            autonomyDefault: policy.autonomyDefault ?? "supervised",
            requireBackups: policy.filePolicy?.requireBackupBeforeWrite ?? true,
            outsideDefault: policy.filePolicy?.outsideWorkspaceDefault ?? "deny",
            developerMode: policy.developerMode,
            autonomousTraining: training.autonomous_training,
            dreamScheduler: training.dream_scheduler,
            routeThroughPromotion: training.route_through_promotion,
            promotionEnabled: promotion.enabled,
            autoPromoteTierA: promotion.auto_promote_tier_a
        )
        isSaving = false
        syncDraftsFromPolicy()
    }
}

// PATCH-2026-05-07: executions-b Permissions panel for autonomous executions
struct WorkshopPermissionsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var draftPolicy = TrustWorkshopPolicy()
    @State private var isSaving = false

    private var workshopExecutionsEnabled: Bool {
        draftPolicy.enabled ?? false
    }
    private var showTimeline: Bool {
        draftPolicy.showTimeline ?? true
    }

    /// Alive glass (2026-09-23): one group card of switch rows.
    var body: some View {
        AliveGroupCard {
            FeatureSwitchRow(
                title: "Allow Desk tasks",
                detail: "I create Desk tasks and plan them in several steps.",
                isOn: Binding(
                    get: { workshopExecutionsEnabled },
                    set: { newValue in
                        Task { await saveWorkshopPolicy(enabled: newValue, showTimeline: showTimeline) }
                    }
                )
            )
            FeatureSwitchRow(
                title: "Show the Desk timeline",
                isOn: Binding(
                    get: { showTimeline },
                    set: { newValue in
                        Task { await saveWorkshopPolicy(enabled: workshopExecutionsEnabled, showTimeline: newValue) }
                    }
                )
            )
            FeatureNote("Desk tasks follow the same approval rules as the rest of my tools. In Full Mac, allowed actions run without asking you again; narrower modes may ask before I send or delete anything.")
        }
        .task { syncDraftPolicy() }
        .onChange(of: appModel.trustPolicy) { _, _ in
            if !isSaving { syncDraftPolicy() }
        }
    }

    private func saveWorkshopPolicy(enabled: Bool, showTimeline: Bool) async {
        draftPolicy.enabled = enabled
        draftPolicy.showTimeline = showTimeline
        isSaving = true
        await appModel.saveWorkshopPolicyToggle(enabled: enabled, showTimeline: showTimeline)
        isSaving = false
        syncDraftPolicy()
    }

    private func syncDraftPolicy() {
        draftPolicy = appModel.trustPolicy?.workshopPolicy ?? TrustWorkshopPolicy()
    }
}

// PATCH-2026-05-07: living-memory Permissions panel for living memory system
struct LivingMemoryPermissionsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var draftPolicy = TrustMemoryPolicy()
    @State private var isSaving = false

    private var pendingCount: Int {
        appModel.memoryProposals.filter { $0.status == "pending" }.count
    }

    /// Alive glass (2026-09-23): one group card of switch rows. Titles match
    /// the same switches on Setup (SetupFeatureRows.swift).
    var body: some View {
        AliveGroupCard(waiting: pendingCount > 0) {
            FeatureSwitchRow(
                title: "Remember across conversations",
                detail: "Each time you write, I look through all our past conversations for what is relevant. Read only; on by default.",
                isOn: Binding(
                    get: { draftPolicy.cross_session_recall },
                    set: { v in
                        var next = draftPolicy
                        next.cross_session_recall = v
                        draftPolicy = next
                        Task { await saveMemoryPolicy(next) }
                    }
                )
            )
            FeatureSwitchRow(
                title: "Nightly memory consolidation",
                detail: MemoryPolicyHelpCopy.nightlyConsolidation,
                isOn: Binding(
                    get: { draftPolicy.consolidation_enabled },
                    set: { v in
                        var next = draftPolicy
                        next.consolidation_enabled = v
                        if !v {
                            next.auto_promote_consolidated = false
                        }
                        draftPolicy = next
                        Task { await saveMemoryPolicy(next) }
                    }
                )
            )
            FeatureSwitchRow(
                title: "Keep consolidated memories without asking",
                detail: MemoryPolicyHelpCopy.autoPromoteConsolidated,
                isOn: Binding(
                    get: { draftPolicy.auto_promote_consolidated },
                    set: { v in
                        var next = draftPolicy
                        next.consolidation_enabled = true
                        next.auto_promote_consolidated = v
                        draftPolicy = next
                        Task { await saveMemoryPolicy(next) }
                    }
                )
            )
            .disabled(!draftPolicy.consolidation_enabled)
            FeatureSwitchRow(
                title: "Knowledge graph",
                detail: "I join up the people, places and things your conversations keep mentioning, and draw them in Memory → Graph.",
                isOn: Binding(
                    get: { draftPolicy.knowledge_graph_enabled },
                    set: { v in
                        var next = draftPolicy
                        next.knowledge_graph_enabled = v
                        draftPolicy = next
                        Task { await patchMemoryPolicy(next, knowledgeGraph: v) }
                    }
                )
            )
            FeatureSwitchRow(
                title: "Memories that recur become facts",
                detail: "When something useful keeps coming back, I suggest keeping it as a lasting fact, without loading all my memory into every reply.",
                isOn: Binding(
                    get: { draftPolicy.adaptive_promotion },
                    set: { v in
                        var next = draftPolicy
                        next.adaptive_promotion = v
                        draftPolicy = next
                        Task { await patchMemoryPolicy(next, adaptivePromotion: v) }
                    }
                )
            )
            FeatureSwitchRow(
                title: "Memory hygiene",
                detail: "I regularly clear out old, noisy, duplicate and low-value memories so they don't pile up.",
                isOn: Binding(
                    get: { draftPolicy.hygiene_enabled },
                    set: { v in
                        var next = draftPolicy
                        next.hygiene_enabled = v
                        draftPolicy = next
                        Task { await patchMemoryPolicy(next, hygiene: v) }
                    }
                )
            )
            if pendingCount > 0 {
                HStack(spacing: 8) {
                    AliveWaitingDot()
                    Text("\(pendingCount) memory suggestion\(pendingCount == 1 ? "" : "s") waiting for you in Memory")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(NativeAgentShell.text)
                }
            }
            // Sweep R4 C9 — COPY ONLY. "harness and promotion proposals"
            // named machinery; the user is being told which page to look on.
            FeatureNote("What I remember, how I recall it, and how I tidy myself up are all set here. Suggested memory changes wait for you in Memory; suggested changes to how I behave wait in Self-Improvement.")
        }
        .task { syncDraftFromPolicy() }
        .onChange(of: appModel.trustPolicy) { _, _ in
            if !isSaving { syncDraftFromPolicy() }
        }
    }

    private func syncDraftFromPolicy() {
        draftPolicy = appModel.trustPolicy?.memoryPolicy ?? TrustMemoryPolicy()
    }

    private func saveMemoryPolicy(_ policy: TrustMemoryPolicy) async {
        isSaving = true
        await appModel.saveMemoryPolicy(
            consolidationEnabled: policy.consolidation_enabled,
            crossSessionRecall: policy.cross_session_recall,
            autoPromoteConsolidated: policy.auto_promote_consolidated
        )
        isSaving = false
        syncDraftFromPolicy()
    }

    private func patchMemoryPolicy(_ draft: TrustMemoryPolicy, knowledgeGraph: Bool? = nil, adaptivePromotion: Bool? = nil, hygiene: Bool? = nil) async {
        isSaving = true
        await appModel.patchMemoryPolicy(
            knowledgeGraphEnabled: knowledgeGraph,
            adaptivePromotion: adaptivePromotion,
            hygieneEnabled: hygiene
        )
        isSaving = false
        syncDraftFromPolicy()
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
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(NativeAgentShell.text)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
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
            .font(.system(size: 12))
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
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    static let autoPromoteConsolidated =
        "Adds those suggestions to your long-term memory profile automatically, instead of waiting for you to approve each one."
}
