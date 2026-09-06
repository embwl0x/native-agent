import Foundation
import Testing
import ChatOrchestration
import MemoryV2
import MultimodalTTS
import NativeAgentCore
import PersistenceCore
import ProviderRouting
@testable import NativeAgentApp

/// Coverage-ledger fence `app.settings` — the Settings / Trust Center controls
/// whose silent-failure mode is "the switch is decoration" or "the number the
/// reader uses is not the number the control showed".
///
/// Rows closed here (docs/evals/ledger.json):
///   * `setting.nativeagent.darkMode`                  (UNCOVERED → dead control, 3 readers)
///   * `setting.nativeagent.compactionThresholdTokens` (REPORTS-ONLY → wrong value / slowdown)
///   * `setting.embeddings.memoryMode`                 (UNCOVERED → wrong value / slowdown)
///   * `setting.telegram.reasoningEffort`              (UNCOVERED → wrong value)
///   * `setting.trust.multimodalPolicy`                (UNCOVERED → dead control)
///   * `setting.voice.autoReadAndOpenAIVoice`          (UNCOVERED → wrong value)
@Suite("app.settings · settings-surface wiring")
struct SettingsSurfaceWiringEvalTests {

    private func tempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-wiring-eval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - setting.nativeagent.darkMode

    /// One preference, three window hosts. Every window-hosting view must read
    /// the SAME defaults key, and no window may hardcode an appearance — a
    /// detached chat panel that stops reading the key drifts from the main
    /// window in a way nobody notices until a screenshot looks wrong.
    @Test func everyWindowHostReadsTheOneDarkModeKeyAndNoneHardcodesAppearance() throws {
        let key = "nativeagent.darkMode"
        let root = try AppSourceScraping.appSourcesRoot()
        let sources = try AppSourceScraping.swiftSourceContents(under: root)

        var appearanceSetters: Set<String> = []
        var keyReaders: Set<String> = []
        for (file, source) in sources {
            if source.contains("preferredColorScheme(") || source.contains("NSAppearance(named:") {
                appearanceSetters.insert(file)
            }
            if source.contains("\"\(key)\"") { keyReaders.insert(file) }
        }

        // The writers (SlimSettingsView, and SetupView since 2e29b8c9 put the
        // same toggle on the Setup page) plus the three window hosts and, since
        // 69fd1891, AppearanceController — the one object that answers "is the
        // window dark?" for both the SwiftUI and AppKit layers.
        // 2026-09-06: set widened for those two commits; the eval's claim is
        // unchanged — one key, and nobody sets an appearance without reading it.
        #expect(keyReaders == [
            "AppearanceController.swift",
            "DetachedChatPanel.swift",
            "DetachedChatPanelView.swift",
            "NativeAgentApp.swift",
            "SetupView.swift",
            "SlimSettingsView.swift",
        ], "dark-mode key readers drifted: \(keyReaders.sorted())")

        let unbacked = appearanceSetters.subtracting(keyReaders)
        #expect(unbacked.isEmpty,
                "these files set an appearance without reading \(key): \(unbacked.sorted())")

        // And each host derives the appearance FROM the preference, not from a
        // literal — flipping any of these to a constant fails here.
        let detached = try AppSourceScraping.appSource("DetachedChatPanelView.swift")
        #expect(detached.contains("preferredColorScheme(preferDarkAppearance ? .dark : nil)"),
                "DetachedChatPanelView.swift must derive its color scheme from the shared preference")
        // 2026-09-06: 69fd1891 — the app's own scenes stopped handing SwiftUI a
        // nil scheme (that left the title bar and rail dark against a white
        // page) and now derive dark-or-light from AppearanceController, which
        // is itself driven by this preference (NativeAgentApp.swift:250, :339).
        // Still derived, never a literal.
        let app = try AppSourceScraping.appSource("NativeAgentApp.swift")
        #expect(app.contains("preferredColorScheme(appearance.colorScheme)"),
                "NativeAgentApp.swift must derive its color scheme from the shared preference")
        #expect(app.contains("appearance.setPreferDark(dark)"))
        let panel = try AppSourceScraping.appSource("DetachedChatPanel.swift")
        #expect(panel.contains("defaults.object(forKey: \"\(key)\") as? Bool"))
        #expect(panel.contains("NSAppearance(named: .darkAqua)"))
    }

    // MARK: - setting.nativeagent.compactionThresholdTokens

    /// The Settings stepper's number is a CEILING, not the threshold: a
    /// smaller-window model compacts at 40% of its window. Pinned at BOTH
    /// stepper endpoints for a small-window and a large-window model, so a
    /// regression that makes the user number authoritative (throwing away
    /// history far too late on a 128k model) or that ignores it entirely
    /// (compacting far too early on a 1M model) fails here.
    @Test func theCompactionStepperNumberIsACeilingNotTheThreshold() throws {
        // Stepper bounds advertised by SlimSettingsView.
        let minimum = 50_000
        let maximum = 500_000
        let view = try AppSourceScraping.appSource("SlimSettingsView.swift")
        #expect(view.contains("in: 50_000...500_000"),
                "the stepper bounds changed — update the endpoints this eval replays")
        #expect(view.contains("@AppStorage(\"\(ChatSessionAutocompactionConfig.defaultsKey)\")"),
                "the stepper must write the same defaults key the autocompactor reads")

        // A 128k-window model: 40% of its window is 51_200, so it clamps the
        // user's ceiling at both ends of the stepper.
        let small = "gpt-5.4"
        #expect(ProviderRouting.verifiedContextLength(forModel: small, providerID: "openai") == 128_000)
        for ceiling in [minimum, maximum] {
            let config = ChatSessionAutocompactionConfig(thresholdTokens: ceiling)
            let effective = config.effectiveThresholdTokens(forModel: small, providerID: "openai")
            #expect(effective == min(ceiling, 51_200),
                    "128k model with ceiling \(ceiling) should compact at \(min(ceiling, 51_200)), got \(effective)")
        }

        // A 1M-window model: 40% is 400_000, so the USER's ceiling wins below
        // that and the model's pressure ceiling wins above it.
        let large = "claude-sonnet-5"
        #expect(ProviderRouting.verifiedContextLength(forModel: large, providerID: "anthropic") == 1_000_000)
        let big = ChatSessionAutocompactionConfig(thresholdTokens: maximum)
        #expect(big.effectiveThresholdTokens(forModel: large, providerID: "anthropic") == 400_000,
                "a 500k ceiling must still yield to the model's 40% pressure ceiling")
        let small2 = ChatSessionAutocompactionConfig(thresholdTokens: minimum)
        #expect(small2.effectiveThresholdTokens(forModel: large, providerID: "anthropic") == minimum,
                "the user's ceiling wins when it is the smaller of the two")

        // An UNKNOWN model has no verified window: fall back to the user's
        // number rather than inventing a pressure ceiling.
        let unknown = ChatSessionAutocompactionConfig(thresholdTokens: 123_456)
        #expect(ProviderRouting.verifiedContextLength(forModel: "not-a-real-model", providerID: "openai") == nil)
        #expect(unknown.effectiveThresholdTokens(forModel: "not-a-real-model", providerID: "openai") == 123_456)
    }

    // MARK: - setting.embeddings.memoryMode

    /// The Memory-mode picker's three tags are a VOCABULARY shared with the
    /// embedding runtime. The runtime normalizes anything it does not
    /// recognize to `balanced`, silently — so a renamed tag (`lowMemory`,
    /// `low-memory`) would leave the segmented control permanently showing
    /// "Balanced" while the user keeps clicking "Low". Cross-vocabulary pin.
    @Test func memoryModePickerTagsAreTheRuntimesOwnModeVocabulary() throws {
        let view = try AppSourceScraping.appSource("SlimSettingsView.swift")
        for tag in [
            ManagedEmbeddingProvider.performanceMode,
            ManagedEmbeddingProvider.balancedMode,
            ManagedEmbeddingProvider.lowMemoryMode,
        ] {
            #expect(view.contains(".tag(\"\(tag)\")"),
                    "the Memory-mode picker must tag segments with the runtime's own `\(tag)` spelling")
        }

        // The third segment is the only one that changes compute units — that
        // is what makes it a live control rather than a label.
        #expect(ManagedEmbeddingProvider.usesCPUOnlyCompute(mode: ManagedEmbeddingProvider.lowMemoryMode) == true)
        #expect(ManagedEmbeddingProvider.usesCPUOnlyCompute(mode: ManagedEmbeddingProvider.balancedMode) == false)
        #expect(ManagedEmbeddingProvider.usesCPUOnlyCompute(mode: ManagedEmbeddingProvider.performanceMode) == false)

        // Negative control for the silent normalization: near-miss spellings
        // are NOT recognized, which is exactly why the tags must match byte
        // for byte.
        for nearMiss in ["lowMemory", "low-memory", "low", "LOW_MEMORY "] {
            #expect(ManagedEmbeddingProvider.usesCPUOnlyCompute(mode: nearMiss)
                        == (nearMiss.trimmingCharacters(in: .whitespaces).lowercased() == "low_memory"),
                    "`\(nearMiss)` must not silently behave like the low-memory tag")
        }
    }

    // MARK: - setting.telegram.reasoningEffort

    /// The Think-level segmented picker derives its options from the CURRENT
    /// model. Switching to a model with a smaller effort set leaves the stored
    /// effort outside the new list and the picker with NO selected segment —
    /// and nothing writes back a valid value. This pins that the mismatch is
    /// at least DETECTABLE from the option list (the fix a caller would need).
    @Test func reasoningEffortOptionsNarrowWithTheModelAndStrandAnOutOfSetChoice() throws {
        let preference = ModelSurfacePreference(model: "small-brain", reasoningEffort: "xhigh")
        let catalog = ModelCatalogResponse(
            status: "ok",
            source: nil,
            defaultModel: "small-brain",
            fallbackModels: [],
            models: [
                ModelCatalogItem(
                    id: "small-brain",
                    displayName: "Small Brain",
                    description: nil,
                    defaultReasoningEffort: "low",
                    supportedReasoningEfforts: ["low", "medium"],
                    supportsFast: nil,
                    priority: 0
                )
            ],
            reasoningEfforts: [
                ReasoningEffortOption(id: "low", label: "Low", description: nil),
                ReasoningEffortOption(id: "medium", label: "Medium", description: nil),
                ReasoningEffortOption(id: "xhigh", label: "XHigh", description: nil),
            ],
            current: ModelRoutingCurrent(chat: preference, telegram: preference),
            updatedAt: nil
        )

        // The STORED telegram effort for this model.
        #expect(catalog.current.telegram.reasoningEffort == "xhigh")

        let narrowed = reasoningOptions(from: catalog, model: "small-brain").map(\.id)
        #expect(narrowed == ["low", "medium"], "options must narrow to the model's supported set")
        #expect(!narrowed.contains("xhigh"),
                "a stored `xhigh` is now out of set — the segmented picker renders with no selection")

        // A model the catalog does not describe falls back to the full list
        // rather than rendering an EMPTY picker (a zero-option segmented
        // control is an unusable control, the worse of the two failures).
        let fallback = reasoningOptions(from: catalog, model: "unlisted-model").map(\.id)
        #expect(fallback == ["low", "medium", "xhigh"])
        #expect(!fallback.isEmpty)
    }

    // MARK: - setting.trust.multimodalPolicy

    /// Reachability pin for the multimodal toggles: a policy key with no
    /// enforcement read site is decoration, and a screen-capture grant that
    /// does nothing is a privacy claim the user believes.
    ///
    /// FOUR of the six are live: `screen_capture`, `image_generation_openai`,
    /// the voice key (`tts_openai`), and — since a6feb944, 2026-09-06,
    /// "Attachments: 'Allow vision API calls' stops images, and an attached PDF
    /// is finally read" — `vision_api_calls` and `file_ingestion_pdf`, both
    /// enforced per turn in ChatOrchestrationClient+MessagePersistence.swift
    /// (:729, :777). ONE remains dead: `file_ingestion_docx` has ZERO
    /// consumers — nothing extracts a DOCX, so the toggle is disabled in the UI
    /// and its stored key is left alone. That gap is recorded here (and
    /// reported as a production seam); this eval fails if a live key loses its
    /// gate OR if the dead key gains one without the ledger being updated.
    @Test func multimodalPolicyKeysAreEnforcedWhereTheToggleClaimsTheyAre() throws {
        let repoRoot = try AppSourceScraping.repositoryRoot()
        let appRoot = try AppSourceScraping.appSourcesRoot()
        let coreRoot = repoRoot.appendingPathComponent("Modules/NativeAgentCore/Sources", isDirectory: true)

        // Files that DEFINE / WRITE / RENDER the policy rather than enforce it.
        let nonEnforcing: Set<String> = [
            "TrustPolicyModels.swift",          // the model
            "TrustPermissionsViews.swift",      // the toggles
            "NativeClient+TrustPolicyActions.swift", // the writer
            "TrustCenter+Defaults.swift",       // shipped defaults
            "TrustCenter+PolicyLoading.swift",  // blank-slate defaults
        ]

        var enforcement: [String: Set<String>] = [:]
        for root in [appRoot, coreRoot] {
            for (file, source) in try AppSourceScraping.swiftSourceContents(under: root) {
                guard !nonEnforcing.contains(file) else { continue }
                for key in ["screen_capture", "vision_api_calls", "file_ingestion_pdf",
                            "file_ingestion_docx", "image_generation_openai", "tts_openai"] {
                    if source.contains(key) { enforcement[key, default: []].insert(file) }
                }
            }
        }

        // 2026-09-06: a6feb944 closed the gap for vision and PDF — both are
        // read fresh per turn, on every lane that can carry an attachment.
        for live in ["screen_capture", "image_generation_openai", "tts_openai",
                     "vision_api_calls", "file_ingestion_pdf"] {
            #expect(!(enforcement[live] ?? []).isEmpty,
                    "DEAD CONTROL: `\(live)` lost every enforcement read site — the toggle is now decoration")
        }
        for dead in ["file_ingestion_docx"] {
            let sites = (enforcement[dead] ?? []).sorted()
            #expect(sites.isEmpty,
                    "GAP CLOSED? `\(dead)` gained a gate at \(sites) — move it to the live list and flip ledger row `setting.trust.multimodalPolicy`.")
        }
    }

    // MARK: - setting.voice.autoReadAndOpenAIVoice

    /// "Use higher-quality OpenAI voice" needs BOTH the Trust Center TTS grant
    /// AND an OpenAI platform key. The real client refuses distinctly for each
    /// missing prerequisite, giving the playback layer an exact preflight
    /// outcome on which it can make its visible local-voice fallback.
    @Test func openAIVoiceRefusesLoudlyWhenEitherPrerequisiteIsMissing() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let trustDir = root.appendingPathComponent("trust", isDirectory: true)
        try FileManager.default.createDirectory(at: trustDir, withIntermediateDirectories: true)

        func writePolicy(ttsAllowed: Bool) throws {
            let payload: [String: Any] = ["multimodalPolicy": ["tts_openai": ttsAllowed]]
            try JSONSerialization.data(withJSONObject: payload)
                .write(to: trustDir.appendingPathComponent("policy.json"))
        }

        // Trust grant missing → trustDenied, BEFORE any key/network work.
        try writePolicy(ttsAllowed: false)
        await #expect(throws: MultimodalTTSError.trustDenied) {
            _ = try await SwiftOpenAITTSClient(apiKeyOverride: "sk-should-not-be-used", dataRoot: root)
                .synthesize(text: "hello", voice: "alloy", format: "mp3")
        }

        // Trust granted but no usable platform key → notConfigured, still no
        // network call. The override is the EMPTY
        // string rather than nil so the assertion never depends on whether the
        // machine running the suite happens to export OPENAI_API_KEY (and can
        // never reach the network).
        try writePolicy(ttsAllowed: true)
        await #expect(throws: MultimodalTTSError.notConfigured) {
            _ = try await SwiftOpenAITTSClient(apiKeyOverride: "", dataRoot: root)
                .synthesize(text: "hello", voice: "alloy", format: "mp3")
        }

        // Both refusals carry an operator-readable reason, so the UI has
        // something honest to show.
        #expect(MultimodalTTSError.trustDenied.errorDescription?.contains("tts_openai") == true)
        #expect(MultimodalTTSError.notConfigured.errorDescription?.contains("OpenAI API key") == true)
    }

    /// A selected OpenAI voice must leave the user with audible output when a
    /// missing grant or key makes a remote request impossible, and the toast
    /// must say exactly which fallback occurred. Network and decode failures
    /// do not take this branch.
    @Test func openAIVoicePreflightFailureFallsBackLocallyWithVisibleReason() {
        #expect(OpenAIVoiceFailureDisposition.resolve(MultimodalTTSError.trustDenied)
            == .fallbackToLocal(
                message: "OpenAI voice is not allowed. Reading aloud with the Mac voice instead."
            ))
        #expect(OpenAIVoiceFailureDisposition.resolve(MultimodalTTSError.notConfigured)
            == .fallbackToLocal(
                message: "OpenAI voice needs an API key. Reading aloud with the Mac voice instead."
            ))
    }
}
