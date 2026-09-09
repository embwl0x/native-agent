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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Chrome control", isOn: Binding(
                    get: { enabled },
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
                .disabled(isSaving)
                .help("Allows \(AgentVoice.live.subject) to use leased background tabs in your signed-in Google Chrome. Off by default.")
                EffectTimingTag(timing: .now)
                Spacer()
            }
            Text("Uses your real Chrome session. \(AgentVoice.live.subject) creates inactive tabs or claims an exact tab, yields immediately when you touch it, and rechecks this switch before every action.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Turning on Chrome control allows access, but the Chrome extension must also be installed and connected. If Chrome is not connected, finish setup below and keep Chrome open.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Set up Chrome", systemImage: "arrow.up.forward.app") {
                setUpChrome()
            }
            .accessibilityIdentifier("trust.chrome.setup")
            Text("1. In Chrome, turn on Developer mode at chrome://extensions.\n2. Click Load unpacked.\n3. Select the NativeAgentChrome folder revealed in Finder. In the folder picker, press Command-Shift-G and paste the folder path shown below if needed.")
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let chromeSetupMessage {
                Text(chromeSetupMessage)
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isSaving {
                ProgressView("Updating Chrome control…")
                    .controlSize(.small)
            }
        }
        .task { syncFromPolicy() }
        .onChange(of: appModel.trustPolicy) { _, _ in
            if !isSaving { syncFromPolicy() }
        }
    }

    private func syncFromPolicy() {
        enabled = appModel.trustPolicy?.chromeControlPolicy?.enabled ?? false
    }

    private func setUpChrome() {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("NativeAgentChrome", isDirectory: true),
              FileManager.default.isReadableFile(atPath: folder.appendingPathComponent("manifest.json").path),
              FileManager.default.isReadableFile(atPath: folder.appendingPathComponent("src/background.js").path),
              FileManager.default.isReadableFile(atPath: folder.appendingPathComponent("src/page-agent.js").path),
              FileManager.default.isReadableFile(atPath: folder.appendingPathComponent("src/user-touch.js").path) else {
            chromeSetupMessage = "This copy of NativeAgent is missing the bundled Chrome extension or has incomplete extension files. Chrome setup cannot continue. Install an app release that includes the extension, or follow the source-checkout instructions in the extension README."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
              let extensions = URL(string: "chrome://extensions") else {
            chromeSetupMessage = "Extension folder: \(folder.path)\nGoogle Chrome could not be found. Install Chrome, then click Set up Chrome again."
            return
        }
        chromeSetupMessage = "Extension folder: \(folder.path)"
        NSWorkspace.shared.open(
            [extensions], withApplicationAt: chrome,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            if error != nil {
                Task { @MainActor in
                    chromeSetupMessage = "Extension folder: \(folder.path)\nChrome could not open the extensions page. Open Chrome and enter chrome://extensions in the address bar, then follow the three steps above."
                }
            }
        }
    }
}

// PATCH-2026-05-06: multimodal-ui Sprint 3 — multimodal permission toggles.
struct MultimodalPermissionsView: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage("voiceAutoRead") private var voiceAutoRead = false
    @State private var draftPolicy = TrustMultimodalPolicy()
    @State private var isSaving = false
    @State private var voiceOutputReadAttempted = false
    @State private var voiceOutputSaveFailure: String?

    private var currentPolicy: TrustMultimodalPolicy {
        draftPolicy
    }

    private var voiceOutputState: VoiceOutputSettingsPresentation.State {
        VoiceOutputSettingsPresentation.resolve(
            trustPolicy: appModel.trustPolicy,
            hasReadAttempted: voiceOutputReadAttempted,
            isSaving: isSaving,
            saveFailure: voiceOutputSaveFailure
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Allow screen capture", isOn: policyBinding(\.screen_capture))
                    .help("NativeAgent will capture your screen when you click the camera button in Chat.")
                EffectTimingTag(timing: .now)
                Spacer()
            }
            HStack {
                Toggle("Allow vision API calls", isOn: policyBinding(\.vision_api_calls))
                    .help("Allows attached images to be sent to the vision model. Uses subscription quota.")
                EffectTimingTag(timing: .now)
                Spacer()
            }
            HStack {
                Toggle("Allow PDF file ingestion", isOn: policyBinding(\.file_ingestion_pdf))
                    .help("The text of a PDF you attach is read into the conversation. Off, the attachment is skipped and the agent is told it was — it never guesses at what the document says. A PDF that is only pictures of pages has no text to read.")
                EffectTimingTag(timing: .now)
                Spacer()
            }
            HStack {
                // 2026-09-06: this said DOC/DOCX attachments are "parsed into
                // chat context". They are not — nothing reads a Word file, and
                // a switch that promises a capability the app does not have is
                // worse than no switch. Disabled and told the truth until the
                // extraction exists; the stored key is left alone so turning it
                // on later needs no migration.
                Toggle("Allow Word document ingestion", isOn: policyBinding(\.file_ingestion_docx))
                    .disabled(true)
                    // 2026-09-06: the copy said DOC as well as DOCX. Both
                    // attachment resolvers accept only .docx — an older .doc is
                    // not carried at all, it is refused at the picker.
                    .help("Not available yet. A .docx attachment is carried with the message but its text is not read into the conversation — attach a PDF, or paste the text. An older .doc file is not accepted at all.")
                EffectTimingTag(timing: .now)
                Spacer()
            }
            HStack {
                Toggle("Allow Codex image generation", isOn: policyBinding(\.image_generation_openai))
                    .help("Allows the image_generate tool to create image files through Codex/ChatGPT OAuth. Optional CLI and OpenAI API fallbacks also use this gate.")
                EffectTimingTag(timing: .now)
                Spacer()
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Label(voiceOutputState.title, systemImage: voiceOutputState.systemImage)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(voiceOutputState.status == "warn" ? Color.orange : Color.secondary)
                Text(voiceOutputState.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if voiceOutputState.canRetry {
                    Button("Reload voice output policy", systemImage: "arrow.clockwise") {
                        Task { await reloadVoiceOutputPolicy() }
                    }
                    .controlSize(.small)
                    .disabled(isSaving)
                    .accessibilityIdentifier("trust.multimodal.voice-output.reload")
                }
            }
            .accessibilityIdentifier("trust.multimodal.voice-output.status")
            HStack {
                Toggle("Read replies aloud automatically", isOn: $voiceAutoRead)
                    .help("New assistant messages are spoken aloud using the saved output route. This preference does not grant OpenAI voice access.")
                    .accessibilityIdentifier("trust.multimodal.voice-output.auto-read")
                EffectTimingTag(timing: .now)
                Spacer()
            }
            HStack {
                Toggle("Use higher-quality OpenAI voice", isOn: Binding(
                    get: { voiceOutputState.remoteVoiceEnabled ?? false },
                    set: { newValue in
                        saveVoiceOutputPolicy(remoteVoiceEnabled: newValue)
                    }
                ))
                .disabled(!voiceOutputState.canChangeRemoteVoice || isSaving)
                .accessibilityIdentifier("trust.multimodal.voice-output.openai")
                EffectTimingTag(timing: .now)
                Spacer()
            }
            Text("OpenAI TTS uses your subscription quota. Requires Trust Center TTS access and an OpenAI platform key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            syncDraftPolicy()
            await reloadVoiceOutputPolicy()
        }
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

    private func saveVoiceOutputPolicy(remoteVoiceEnabled: Bool) {
        guard var next = appModel.trustPolicy?.multimodalPolicy else {
            voiceOutputSaveFailure = "Reload the Trust policy before changing the OpenAI voice setting."
            return
        }
        next.tts_openai = remoteVoiceEnabled
        draftPolicy = next
        voiceOutputSaveFailure = nil
        Task {
            isSaving = true
            let saved = await appModel.saveMultimodalPolicy(next)
            isSaving = false
            if saved {
                voiceOutputSaveFailure = nil
            } else {
                voiceOutputSaveFailure = appModel.statusText
            }
            syncDraftPolicy()
        }
    }

    private func reloadVoiceOutputPolicy() async {
        voiceOutputReadAttempted = true
        let loaded = await appModel.refreshVoiceOutputPolicy()
        if loaded {
            voiceOutputSaveFailure = nil
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
    @State private var draftTraining = TrustTrainingPolicy()
    @State private var draftPromotion = TrustPromotionPolicy()
    @State private var isSaving = false
    /// The EFFECTIVE dream gate (dream_scheduler AND dream_cycle_enabled), read
    /// through the same composite the Dreams page and Setup read. `trustPolicy`
    /// carries no personalityPolicy block, so it cannot come from the drafts.
    @State private var draftDreamComposite = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                // Sweep R4 C9 — COPY ONLY. "improvement kernel" named an
                // internal component, not a thing the user grants.
                Toggle(
                    "Let the agent improve itself in the background",
                    isOn: Binding(
                        get: { draftEnableAutonomy },
                        set: { newValue in
                            draftEnableAutonomy = newValue
                            Task { await saveEnableAutonomy(newValue) }
                        }
                    )
                )
                .help("The master switch for everything on this card. Even when it is on, the agent can only change its own files inside NativeAgent — never the rest of your Mac.")
                EffectTimingTag(timing: .restart)
                Spacer()
            }
            Divider()
            // Taste pass 2026-07-24: was "Autonomous Training", an exact echo
            // of the card title directly above it.
            Text("Practice Runs")
                .font(.headline)
            HStack {
                Toggle(
                    "Let the agent practice on its own",
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
                // Sweep R4 C9 — COPY ONLY. Was a raw endpoint path for a
                // daemon that no longer exists (README "What exists today":
                // the Swift app owns the runtime in-process).
                .help("The agent works through its own saved exercises in the background, notices where its answers have slipped, and writes up suggested changes. It never applies a change on its own — every suggestion waits for you.")
                EffectTimingTag(timing: .nextRun)
                Spacer()
            }
            HStack {
                Toggle(
                    "Run dream cycle nightly",
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
                .help("Once a night at 3:30 AM the agent looks back over recent conversations and what it learned that day, writes it up as a dated diary entry, and leaves you a short digest in the morning. Needs practice runs turned on above.")
                EffectTimingTag(timing: .nextRun)
                Spacer()
            }

            Divider()

            // PATCH-2026-05-07: self-improvement-ui Promotion engine trust toggles
            // Sweep R4 C9 — COPY ONLY. "Promotion engine" was the internal
            // component name; what the user is granting is an automatic
            // check that a proposed change is good enough to keep.
            Text("Automatic Review")
                .font(.headline)
            HStack {
                Toggle(
                    "Check proposed changes automatically",
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
                // Sweep R4 C9 — COPY ONLY. Was a raw endpoint path plus
                // "harness eval", neither of which appears anywhere else
                // in the UI.
                .help("Before any suggested change is kept, the agent re-runs its own test set against it. A change that scores worse than what it replaces is thrown away instead of applied.")
                EffectTimingTag(timing: .nextRun)
                Spacer()
            }
            HStack {
                Toggle(
                    "Keep low-risk changes without asking me (personality notes, practice exercises)",
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
                // Sweep R4 C9 — COPY ONLY. "Tier A acts as Tier B" was the
                // only place those tiers were ever named; nothing in the UI
                // defined either one.
                .help("Low-risk means the agent's own notes about how it should behave and the exercises it practices against — never your files or your settings. With this off, every change waits for your sign-off no matter how small. Turn it on only if you trust the automatic check above to catch a bad one.")
                EffectTimingTag(timing: .nextRun)
                Spacer()
            }
            HStack {
                Toggle(
                    "Put practice suggestions through the automatic check too",
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
                .help("A suggestion you approve is still tested before it is written, instead of being applied straight away. Needs both practice runs and automatic review turned on.")
                EffectTimingTag(timing: .nextRun)
                Spacer()
            }

            Text("Autonomous training is propose-only. Corrections to SOUL/VOICE never apply without your approval.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            syncDraftsFromPolicy()
            await refreshDreamComposite()
        }
        .onChange(of: appModel.trustPolicy) { _, _ in
            if !isSaving {
                syncDraftsFromPolicy()
                Task { await refreshDreamComposite() }
            }
        }
    }

    private func refreshDreamComposite() async {
        draftDreamComposite = await appModel.client.swiftDreamCompositeEnabled()
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle(
                    "Allow Desk task execution",
                    isOn: Binding(
                        get: { workshopExecutionsEnabled },
                        set: { newValue in
                            Task { await saveWorkshopPolicy(enabled: newValue, showTimeline: showTimeline) }
                        }
                    )
                )
                .help("Allows Swift-native Desk task creation and multi-step planning.")
                EffectTimingTag(timing: .nextRun)
                Spacer()
            }
            HStack {
                Toggle(
                    "Show Desk execution timeline",
                    isOn: Binding(
                        get: { showTimeline },
                        set: { newValue in
                            Task { await saveWorkshopPolicy(enabled: workshopExecutionsEnabled, showTimeline: newValue) }
                        }
                    )
                )
                EffectTimingTag(timing: .now)
                Spacer()
            }
            Text("Desk execution follows app-wide tool autonomy. Read-only tools run without prompting; sends and destructive actions require approval.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle(
                    "Cross-session memory recall",
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
                .help("Per-turn: the agent retrieves relevant memories from all past sessions (read-only, default on).")
                EffectTimingTag(timing: .now)
                Spacer()
            }
            HStack {
                Toggle(
                    "Nightly memory consolidation",
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
                .help(MemoryPolicyHelpCopy.nightlyConsolidation)
                EffectTimingTag(timing: .nextRun)
                Spacer()
            }
            HStack {
                Toggle(
                    "Auto-promote consolidated memories",
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
                .help(MemoryPolicyHelpCopy.autoPromoteConsolidated)
                EffectTimingTag(timing: .nextRun)
                Spacer()
            }
            Divider()
            HStack {
                Toggle(
                    "Knowledge Graph",
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
                .help("Builds entity links from conversations and powers Memory → Graph.")
                EffectTimingTag(timing: .now)
                Spacer()
            }
            HStack {
                Toggle(
                    "Adaptive memory promotion",
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
                .help("Allows recurring high-value memories to become proposed durable facts without loading all memory into each chat turn.")
                EffectTimingTag(timing: .nextRun)
                Spacer()
            }
            HStack {
                Toggle(
                    "Memory hygiene",
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
                .help("Runs regular cleanup so old, noisy, duplicate, and low-value memory does not accumulate forever.")
                EffectTimingTag(timing: .nextRun)
                Spacer()
            }
            if pendingCount > 0 {
                Label("\(pendingCount) memory proposal\(pendingCount == 1 ? "" : "s") pending — review in Memory", systemImage: "brain.head.profile")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            // Sweep R4 C9 — COPY ONLY. "harness and promotion proposals"
            // named machinery; the user is being told which page to look on.
            Text("What the agent remembers, how it recalls it, and how it tidies itself up are all set here. Suggested memory changes wait for you in Memory; suggested changes to how the agent behaves wait in Self-Improvement.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        "Once a night, the agent looks for things that keep coming up in your conversations and suggests them for your long-term memory profile."

    static let autoPromoteConsolidated =
        "Adds those suggestions to your long-term memory profile automatically, instead of waiting for you to approve each one."
}
