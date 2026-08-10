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

// PATCH-2026-05-06: multimodal-ui Sprint 3 — multimodal permission toggles.
struct MultimodalPermissionsView: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage("voiceAutoRead") private var voiceAutoRead = false
    @AppStorage("voiceUseOpenAI") private var voiceUseOpenAI = false
    @State private var draftPolicy = TrustMultimodalPolicy()
    @State private var isSaving = false

    private var currentPolicy: TrustMultimodalPolicy {
        draftPolicy
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
                    .help("Allows PDF attachments to be parsed into chat context.")
                EffectTimingTag(timing: .now)
                Spacer()
            }
            HStack {
                Toggle("Allow Word document ingestion", isOn: policyBinding(\.file_ingestion_docx))
                    .help("Allows DOC and DOCX attachments to be parsed into chat context.")
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
            HStack {
                Toggle("Read replies aloud automatically", isOn: $voiceAutoRead)
                    .help("New assistant messages are spoken aloud using the selected voice mode.")
                EffectTimingTag(timing: .now)
                Spacer()
            }
            HStack {
                Toggle("Use higher-quality OpenAI voice", isOn: Binding(
                    get: { currentPolicy.tts_openai },
                    set: { newValue in
                        voiceUseOpenAI = newValue
                        savePolicy(\.tts_openai, value: newValue)
                    }
                ))
                EffectTimingTag(timing: .now)
                Spacer()
            }
            Text("OpenAI TTS uses your subscription quota. Requires Trust Center TTS access and an OpenAI platform key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { syncDraftPolicy() }
        .onChange(of: draftPolicy.tts_openai) { _, newValue in voiceUseOpenAI = newValue }
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
            await appModel.saveMultimodalPolicy(next)
            isSaving = false
            syncDraftPolicy()
        }
    }

    private func syncDraftPolicy() {
        draftPolicy = appModel.trustPolicy?.multimodalPolicy ?? TrustMultimodalPolicy()
        voiceUseOpenAI = draftPolicy.tts_openai
    }
}

// PATCH-2026-05-07: training-b1 ui Permissions panel for autonomous training loop.
struct TrainingPermissionsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var draftEnableAutonomy = false
    @State private var draftTraining = TrustTrainingPolicy()
    @State private var draftPromotion = TrustPromotionPolicy()
    @State private var isSaving = false

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
                        get: { draftTraining.dream_scheduler },
                        set: { newValue in
                            var next = draftTraining
                            next.autonomous_training = true
                            next.dream_scheduler = newValue
                            draftTraining = next
                            Task { await saveAll(training: next, promotion: draftPromotion) }
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
        .task { syncDraftsFromPolicy() }
        .onChange(of: appModel.trustPolicy) { _, _ in
            if !isSaving { syncDraftsFromPolicy() }
        }
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

struct TrustPolicyTile: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value.replacingOccurrences(of: "_", with: " "))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct TrustBoundaryRow: View {
    var title: String
    var detail: String
    var systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
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
