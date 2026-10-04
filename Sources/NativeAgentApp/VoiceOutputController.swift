import AppToolRuntime
// PATCH-2026-05-06: multimodal-ui Sprint 3.2 — voice output via AVSpeechSynthesizer + optional OpenAI TTS
import Foundation
import AVFoundation
import Observation
import NativeAgentCore
import MultimodalTTS
import PersistenceCore
import ProviderRouting
import TrustCenter

enum VoiceOutputMode: String, CaseIterable, Identifiable {
    case local = "local"
    case openai = "openai"
    var id: String { rawValue }
}

/// The selected playback route, or why it could not be read. An unreadable
/// Trust policy reads nothing aloud — it no longer falls back to the Mac voice
/// behind a notice (S12, 2026-09-26).
enum VoiceOutputModeResolution: Equatable {
    case openAI
    case localConfigured
    case policyUnreadable(reason: String)
}

/// Read-aloud has one selection owner: the loaded Trust Center policy.  The
/// old `voiceUseOpenAI` AppStorage mirror could outlive a denied policy write,
/// leaving the settings screen and either chat read site on different modes.
enum VoiceOutputModeSelection {
    static func resolve(for trustPolicy: TrustPolicy) -> VoiceOutputModeResolution {
        trustPolicy.multimodalPolicy?.tts_openai == true ? .openAI : .localConfigured
    }

    /// The policy as loaded. When none is loaded yet (first load still
    /// pending, or an earlier load failed) this makes one checked read now
    /// rather than guessing a voice: it answers with the policy, or with why
    /// the policy could not be read.
    @MainActor
    static func resolve(trust: TrustFacade) async -> VoiceOutputModeResolution {
        if let policy = trust.policy { return resolve(for: policy) }
        do {
            return resolve(for: try await trust.load())
        } catch {
            return .policyUnreadable(reason: error.localizedDescription)
        }
    }
}

/// A selected OpenAI voice that cannot speak says so and reads nothing — it
/// never switches to the Mac voice (S12, 2026-09-26). Preflight failures get a
/// plain sentence; every other failure surfaces its own description.
enum OpenAIVoiceFailure {
    static func message(for error: Error) -> String {
        switch error {
        case MultimodalTTSError.trustDenied:
            return "OpenAI voice is not allowed in Trust Center. Nothing was read aloud."
        case MultimodalTTSError.notConfigured:
            return "OpenAI voice needs an API key in Settings → Providers → OpenAI. Nothing was read aloud."
        case MultimodalTTSError.routeHasNoSpeech:
            // Chat's provider has no speech API at all. Say so plainly; never
            // quietly call a different provider or another voice.
            return "The provider Chat runs on has no cloud voice. Nothing was read aloud."
        default:
            return error.localizedDescription
        }
    }
}

@Observable
@MainActor
final class VoiceOutputController: NSObject {
    typealias OpenAISynthesis = @Sendable (_ text: String) async throws -> Data

    /// Manual message playback is globally singular: starting one bubble must
    /// stop the previous bubble instead of allowing several speech engines to
    /// talk over one another. Auto-read keeps its separate ChatView owner.
    static let sharedMessagePlayback = VoiceOutputController()

    var isSpeaking: Bool = false
    var errorMessage: String? = nil
    private(set) var speechOwnerID: String? = nil
    private(set) var errorOwnerID: String? = nil

    private var synthesizer: AVSpeechSynthesizer?
    private var audioPlayer: AVAudioPlayer?
    private var pendingSynthesis: Task<Data, Error>?
    // Bumped on every speak()/stop() so an in-flight speakOpenAI can detect it was superseded across its network await.
    private(set) var speechGeneration: Int = 0
    private let openAISynthesis: OpenAISynthesis
    private let audioPlayerFactory: (Data) throws -> AVAudioPlayer

    override convenience init() {
        self.init(openAISynthesis: Self.liveOpenAISynthesis)
    }

    init(
        audioPlayerFactory: @escaping (Data) throws -> AVAudioPlayer = { try AVAudioPlayer(data: $0) },
        openAISynthesis: @escaping OpenAISynthesis
    ) {
        self.audioPlayerFactory = audioPlayerFactory
        self.openAISynthesis = openAISynthesis
        super.init()
    }

    /// SwiftUI may retain several controller state locations while chat
    /// surfaces are rebuilt. A synthesizer carries system speech-service state,
    /// so create it only for an actual local utterance instead of once per
    /// mounted controller.
    private func localSynthesizer() -> AVSpeechSynthesizer {
        if let synthesizer { return synthesizer }
        let created = AVSpeechSynthesizer()
        created.delegate = self
        synthesizer = created
        return created
    }

    var _localSynthesizerPreparedForTesting: Bool { synthesizer != nil }

    func speak(
        text: String,
        mode: VoiceOutputMode = .local,
        ownerID: String? = nil
    ) async {
        guard !text.isEmpty else { return }
        // Quiet mode is enforced HERE, at the one door both routes go through,
        // so "no audio out" holds for every caller that exists and every one
        // added later. stop() first: switching quiet on mid-utterance must
        // silence what is already speaking, not merely decline the next thing.
        guard !VoicePreference.quiet() else {
            stop()
            return
        }
        stop()
        speechGeneration &+= 1
        speechOwnerID = ownerID
        errorMessage = nil
        errorOwnerID = nil
        isSpeaking = true
        switch mode {
        case .local:
            speakLocal(text: text)
        case .openai:
            await speakOpenAI(text: text)
        }
    }

    /// Speak on the route `trust`'s policy selects. A stop() or a newer
    /// speak() while the policy is still being read wins: this request then
    /// plays nothing (dictation stopping playback must not be undone by a
    /// read that finishes after it).
    func speak(text: String, trust: TrustFacade, ownerID: String? = nil) async {
        let generation = speechGeneration
        let resolution = await VoiceOutputModeSelection.resolve(trust: trust)
        guard generation == speechGeneration else { return }
        await speak(text: text, resolution: resolution, ownerID: ownerID)
    }

    /// Speak on the route the Trust policy selects. An unreadable policy says
    /// so on the owning surface and reads nothing.
    func speak(
        text: String,
        resolution: VoiceOutputModeResolution,
        ownerID: String? = nil
    ) async {
        switch resolution {
        case .openAI:
            await speak(text: text, mode: .openai, ownerID: ownerID)
        case .localConfigured:
            await speak(text: text, mode: .local, ownerID: ownerID)
        case .policyUnreadable(let reason):
            stop()
            guard !text.isEmpty, !VoicePreference.quiet() else { return }
            errorMessage = "Voice policy could not be read (\(reason)). Nothing was read aloud."
            errorOwnerID = ownerID
        }
    }

    func isSpeaking(ownerID: String) -> Bool {
        isSpeaking && speechOwnerID == ownerID
    }

    func consumeError(ownerID: String) -> String? {
        guard errorOwnerID == ownerID, let errorMessage else { return nil }
        self.errorMessage = nil
        errorOwnerID = nil
        return errorMessage
    }

    func stop() {
        speechGeneration &+= 1
        pendingSynthesis?.cancel()
        pendingSynthesis = nil
        synthesizer?.stopSpeaking(at: .immediate)
        // Wave 35 W18: detach the delegate BEFORE dropping the reference so a
        // superseded player can never deliver a stale didFinish/decodeError that
        // would stomp a newer playback's state. This is the sound supersession
        // guard — it removes the stale-callback PATH entirely, rather than
        // racing an ObjectIdentifier comparison (which an address-reused new
        // player could theoretically false-match).
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isSpeaking = false
        speechOwnerID = nil
    }

    // MARK: Private

    private func speakLocal(text: String) {
        let utterance = GenerationTaggedUtterance(string: text, generation: speechGeneration)
        // An unset or unrecognised name leaves `voice` nil, which is the Mac's
        // own chosen system voice — what shipped before this was settable.
        let chosenVoice = VoicePreference.name()
        if !chosenVoice.isEmpty {
            utterance.voice = AVSpeechSynthesisVoice(identifier: chosenVoice)
                ?? AVSpeechSynthesisVoice(language: chosenVoice)
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        localSynthesizer().speak(utterance)
        // isSpeaking set to false by delegate when done
    }

    private func speakOpenAI(text: String) async {
        // Snapshot the current generation; if stop()/speak() runs during the network await,
        // it bumps speechGeneration and we must not clobber the new state when we resume.
        let generation = speechGeneration
        let synthesis = Task { [openAISynthesis] in
            try Task.checkCancellation()
            return try await openAISynthesis(text)
        }
        pendingSynthesis = synthesis
        defer {
            if generation == speechGeneration { pendingSynthesis = nil }
        }
        do {
            // Swift-native TTS: direct URLSession POST to OpenAI's
            // /v1/audio/speech through SwiftOpenAITTSClient. The key is
            // resolved against PersistenceCore.defaultDataRoot(), so an
            // installed .app bundle reads the app-owned provider config instead
            // of a CWD-relative path.
            let audioData: Data
            audioData = try await withTaskCancellationHandler {
                try await synthesis.value
            } onCancel: {
                synthesis.cancel()
            }
            // Superseded by a concurrent stop()/speak() while awaiting — bail without touching shared state.
            guard generation == speechGeneration else { return }
            // Injected or underlying synthesis may ignore cancellation and still return bytes.
            try Task.checkCancellation()
            // Detach any prior player's delegate before replacing it, so a
            // superseded player can't fire a stale callback (Wave 35 W18).
            audioPlayer?.delegate = nil
            let player = try audioPlayerFactory(audioData)
            player.delegate = self
            audioPlayer = player
            guard player.play() else {
                errorMessage = "Audio playback could not start. Try reading aloud again."
                errorOwnerID = speechOwnerID
                stop()
                return
            }
            isSpeaking = true
        } catch {
            // Don't report/clear state if a concurrent stop()/speak() already superseded this call.
            guard generation == speechGeneration else { return }
            if Task.isCancelled || error is CancellationError {
                stop()
                return
            }
            errorMessage = OpenAIVoiceFailure.message(for: error)
            errorOwnerID = speechOwnerID
            isSpeaking = false
            speechOwnerID = nil
        }
    }

    /// Cloud read-aloud resolves under Chat's route: the provider the person
    /// chose for the Chat group is the one asked to speak, and the model comes
    /// from that route's catalog entry. A route with no speech model refuses
    /// here — it never borrows another provider's voice or a model literal
    /// (2026-09-13 rulings), and nothing is read aloud.
    nonisolated private static func liveOpenAISynthesis(text: String) async throws -> Data {
        let dataRoot = PersistenceCore.defaultDataRoot()
        let router = SwiftNativeProviderRouting(
            dataRoot: dataRoot,
            surfacesPathOverride: dataRoot
                .appendingPathComponent("providers", isDirectory: true)
                .appendingPathComponent("surfaces.json"),
            activeProviderPathOverride: dataRoot
                .appendingPathComponent("providers", isDirectory: true)
                .appendingPathComponent("active.json")
        )
        let snapshot = try? await router.checkedRoutingSnapshot()
        // S12a: Chat's chosen route only, never one inferred from its model.
        let chatProvider = snapshot.flatMap {
            ProviderRoutingSurfaceLookup.value($0.activeProviders, "chat")
        }
        guard let chatProvider,
              let model = FirstPartyModelCatalog.speechModel(forProviderID: chatProvider) else {
            throw MultimodalTTSError.routeHasNoSpeech(route: "Chat's provider")
        }
        return try await SwiftOpenAITTSClient(model: model)
            .synthesize(text: text, voice: VoicePreference.cloudVoice(), format: "mp3")
    }
}

// Same supersession guard as the wave 35 W18 audio-player fix, applied to the
// synthesizer path: speak() after stop() let the OLD utterance's didCancel
// (async MainActor hop) flip isSpeaking=false AFTER the new utterance set it
// true, making the Stop button unreachable. The synthesizer delegate can't be
// detached per-utterance, so each utterance carries the generation it was
// created under; the state-clear is ignored once the generation has advanced.
final class GenerationTaggedUtterance: AVSpeechUtterance {
    let generation: Int
    init(string: String, generation: Int) {
        self.generation = generation
        super.init(string: string)
    }
    required init?(coder: NSCoder) {
        // Never decoded — utterances are only created via init(string:generation:).
        return nil
    }
    // AVSpeechUtterance is NSCopying; if AVFoundation ever copies the
    // utterance internally, a plain copy would strip the subclass tag and
    // re-open the stale-callback stomp this class exists to prevent
    // (gpt-5.5 review). Preserve the generation across copies.
    override func copy(with zone: NSZone? = nil) -> Any {
        let copied = GenerationTaggedUtterance(string: speechString, generation: generation)
        copied.rate = rate
        copied.pitchMultiplier = pitchMultiplier
        copied.volume = volume
        copied.voice = voice
        copied.preUtteranceDelay = preUtteranceDelay
        copied.postUtteranceDelay = postUtteranceDelay
        return copied
    }
}

extension VoiceOutputController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let generation = (utterance as? GenerationTaggedUtterance)?.generation
        Task { @MainActor in
            if let generation, generation != self.speechGeneration { return }
            self.isSpeaking = false
            self.speechOwnerID = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let generation = (utterance as? GenerationTaggedUtterance)?.generation
        Task { @MainActor in
            if let generation, generation != self.speechGeneration { return }
            self.isSpeaking = false
            self.speechOwnerID = nil
        }
    }
}

extension VoiceOutputController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Delegate detachment cannot retract a callback already queued.
        let playerID = ObjectIdentifier(player)
        Task { @MainActor in
            guard self.audioPlayer.map(ObjectIdentifier.init) == playerID else { return }
            self.audioPlayer = nil
            self.isSpeaking = false
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let playerID = ObjectIdentifier(player)
        let message = error?.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            guard self.audioPlayer.map(ObjectIdentifier.init) == playerID else { return }
            self.audioPlayer = nil
            self.errorOwnerID = self.speechOwnerID
            self.errorMessage = message.flatMap { $0.isEmpty ? nil : $0 } ?? "The audio couldn't be played."
            self.isSpeaking = false
            self.speechOwnerID = nil
        }
    }
}
