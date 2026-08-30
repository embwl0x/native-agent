// PATCH-2026-05-06: multimodal-ui Sprint 3.2 — voice output via AVSpeechSynthesizer + optional OpenAI TTS
import Foundation
import AVFoundation
import Observation
import NativeAgentCore
import MultimodalTTS

enum VoiceOutputMode: String, CaseIterable, Identifiable {
    case local = "local"
    case openai = "openai"
    var id: String { rawValue }
}

/// The selected playback route plus the provenance for a local fallback.
/// Local speech is a legitimate configured choice, but it must not hide an
/// unread Trust policy behind the same success-shaped mode label.
enum VoiceOutputModeResolution: Equatable {
    case openAI
    case localConfigured
    case localPolicyUnavailable

    var mode: VoiceOutputMode {
        switch self {
        case .openAI: .openai
        case .localConfigured, .localPolicyUnavailable: .local
        }
    }

    var notice: String? {
        guard case .localPolicyUnavailable = self else { return nil }
        return "Voice policy is unavailable. Reading aloud with the Mac voice instead."
    }
}

/// Read-aloud has one selection owner: the loaded Trust Center policy.  The
/// old `voiceUseOpenAI` AppStorage mirror could outlive a denied policy write,
/// leaving the settings screen and either chat read site on different modes.
enum VoiceOutputModeSelection {
    static func resolve(for trustPolicy: TrustPolicy?) -> VoiceOutputModeResolution {
        guard let trustPolicy else { return .localPolicyUnavailable }
        return trustPolicy.multimodalPolicy?.tts_openai == true ? .openAI : .localConfigured
    }

    static func mode(for trustPolicy: TrustPolicy?) -> VoiceOutputMode {
        resolve(for: trustPolicy).mode
    }
}

/// A selected OpenAI voice is allowed to fall back only for preflight failures
/// that make a remote request impossible. Transport and decode failures remain
/// loud: silently changing voices after a real request is misleading.
enum OpenAIVoiceFailureDisposition: Equatable {
    case fallbackToLocal(message: String)
    case surfaceFailure(message: String)

    static func resolve(_ error: Error) -> Self {
        switch error {
        case MultimodalTTSError.trustDenied:
            return .fallbackToLocal(
                message: "OpenAI voice is not allowed. Reading aloud with the Mac voice instead."
            )
        case MultimodalTTSError.notConfigured:
            return .fallbackToLocal(
                message: "OpenAI voice needs an API key. Reading aloud with the Mac voice instead."
            )
        default:
            return .surfaceFailure(message: error.localizedDescription)
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
    // Weak back-reference for app runtime settings, set by ChatView on init.
    var nativeBaseURL: String = ""

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

    /// Preserve the policy-read result through the playback boundary. The
    /// actual fallback is still local AVSpeechSynthesizer, while the mounted
    /// chat surface receives a truthful notice when policy evidence was absent.
    func speak(
        text: String,
        resolution: VoiceOutputModeResolution,
        ownerID: String? = nil
    ) async {
        await speak(text: text, mode: resolution.mode, ownerID: ownerID)
        if let notice = resolution.notice, isSpeaking {
            errorMessage = notice
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

    func pause() {
        synthesizer?.pauseSpeaking(at: .word)
        audioPlayer?.pause()
    }

    func resume() {
        synthesizer?.continueSpeaking()
        audioPlayer?.play()
    }

    // MARK: Private

    private func speakLocal(text: String) {
        let utterance = GenerationTaggedUtterance(string: text, generation: speechGeneration)
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
            switch OpenAIVoiceFailureDisposition.resolve(error) {
            case .fallbackToLocal(let message):
                errorMessage = message
                errorOwnerID = speechOwnerID
                speakLocal(text: text)
            case .surfaceFailure(let message):
                errorMessage = message
                errorOwnerID = speechOwnerID
                isSpeaking = false
                speechOwnerID = nil
            }
        }
    }

    nonisolated private static func liveOpenAISynthesis(text: String) async throws -> Data {
        try await SwiftOpenAITTSClient().synthesize(text: text, voice: "alloy", format: "mp3")
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
        // Wave 35 W18: superseded players have their delegate detached in
        // stop()/speakOpenAI before replacement, so only the CURRENT player ever
        // reaches here — no identity comparison needed (and capturing the
        // non-Sendable player into the @MainActor hop would be a Swift 6 race).
        Task { @MainActor in
            self.audioPlayer = nil
            self.isSpeaking = false
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let message = error?.localizedDescription
        Task { @MainActor in
            self.audioPlayer = nil
            self.errorMessage = message
            self.isSpeaking = false
        }
    }
}
