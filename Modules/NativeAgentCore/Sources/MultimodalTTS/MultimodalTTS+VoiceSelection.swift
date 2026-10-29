import Foundation
import PersistenceCore
import ProviderRouting
import TrustCenter
import AVFoundation
import Observation
import os
// Blueprint: | `MultimodalTTS+VoiceSelection.swift` | voice authority/routing, native/cloud playback, generations/cancellation; `VoicePreference`: `quiet`, `name`; auto-read decision |

/// An unreadable Trust policy prevents read-aloud and reports why.
public enum VoiceOutputModeResolution: Equatable {
    case openAI
    case localConfigured
    case policyUnreadable(reason: String)
}

/// Read-aloud has one selection owner: the loaded Trust Center policy.
public enum VoiceOutputModeSelection {
    public static func resolve(for trustPolicy: TrustPolicy) -> VoiceOutputModeResolution {
        trustPolicy.multimodalPolicy?.tts_openai == true ? .openAI : .localConfigured
    }

    /// The policy as loaded. When none is loaded yet (first load still
    /// pending, or an earlier load failed) this makes one checked read now
    /// rather than guessing a voice: it answers with the policy, or with why
    /// the policy could not be read.
    @MainActor
    public static func resolve(
        policy: TrustPolicy?,
        loadPolicy: @MainActor () async throws -> TrustPolicy,
        failureCause: (Error, String) -> String
    ) async -> VoiceOutputModeResolution {
        if let policy { return resolve(for: policy) }
        do {
            return resolve(for: try await loadPolicy())
        } catch {
            return .policyUnreadable(reason: failureCause(error, "read the voice policy"))
        }
    }
}

extension SwiftOpenAITTSClient {
    /// Cloud read-aloud uses only Chat's provider and its catalog speech model.
    public static func synthesizeChat(text: String, voice: @Sendable () -> String) async throws -> (audio: Data, unread: Int) {
        let dataRoot = PersistenceCore.defaultDataRoot()
        let router = SwiftNativeProviderRouting(dataRoot: dataRoot)
        // An unreadable route is its own failure, never evidence about that route's voice.
        let snapshot = try await router.checkedRoutingSnapshot()
        // Chat's chosen route only, never one inferred from its model.
        guard let chatProvider = ProviderRoutingSurfaceLookup.value(snapshot.activeProviders, "chat"),
              let model = FirstPartyModelCatalog.speechModel(forProviderID: chatProvider) else {
            throw MultimodalTTSError.routeHasNoSpeech(route: "Chat's provider")
        }
        return try await SwiftOpenAITTSClient(model: model)
            .synthesize(text: text, voice: voice(), format: "mp3")
    }
}

/// Read-aloud's voice and the one switch that guarantees silence.
///
/// `quiet` is deliberately enforced at `VoiceOutputController.speak`, the
/// single door both routes go through, rather than at each caller: a promise
/// of "no audio out" that depends on every future call site remembering to ask
/// is not a promise. The tool that renders speech to a FILE is unaffected, and
/// correctly so — it never opens an output device.
///
/// `name` is empty by default, which means the Mac's chosen system voice
/// locally and the route's default voice in the cloud.
public enum VoicePreference {
    public static let quietKey = "nativeagent.voice.quiet"
    public static let nameKey = "nativeagent.voice.name"

    /// An unset cloud voice uses alloy.
    public static let cloudDefaultName = "alloy"

    public static func quiet(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: quietKey)
    }

    public static func name(in defaults: UserDefaults = .standard) -> String {
        (defaults.string(forKey: nameKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func cloudVoice(in defaults: UserDefaults = .standard) -> String {
        let chosen = name(in: defaults)
        return chosen.isEmpty ? cloudDefaultName : chosen
    }
}


/// OpenAI voice failures report plainly and read nothing; they never switch voices.
private enum OpenAIVoiceFailure {
    static func message(for error: Error, failureMessage: (Error, String) -> String) -> String {
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
            return failureMessage(error, "read that aloud")
        }
    }
}

@Observable
@MainActor
public final class VoiceOutputController: NSObject {
    public var isSpeaking: Bool = false
    public var errorMessage: String? = nil
    public private(set) var speechOwnerID: String? = nil
    public private(set) var errorOwnerID: String? = nil

    private var synthesizer: AVSpeechSynthesizer?
    private var audioPlayer: AVAudioPlayer?
    private var pendingSynthesis: Task<(audio: Data, unread: Int), Error>?
    // Bumped on every speak()/stop() so an in-flight speakOpenAI can detect it was superseded across its network await.
    private var speechGeneration: Int = 0
    private let failureMessage: @Sendable (Error, String) -> String
    private let failureCause: @Sendable (Error, String) -> String

    public init(
        failureMessage: @escaping @Sendable (Error, String) -> String,
        failureCause: @escaping @Sendable (Error, String) -> String
    ) {
        self.failureMessage = failureMessage
        self.failureCause = failureCause
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

    /// Speak on the route `trust`'s policy selects. A stop() or a newer
    /// speak() while the policy is still being read wins: this request then
    /// plays nothing (dictation stopping playback must not be undone by a
    /// read that finishes after it).
    public func speak(
        text: String,
        policy: TrustPolicy?,
        loadPolicy: @MainActor () async throws -> TrustPolicy,
        ownerID: String? = nil
    ) async {
        // Admission order, not policy-read completion order, owns playback.
        speechGeneration &+= 1
        let generation = speechGeneration
        let resolution = await VoiceOutputModeSelection.resolve(policy: policy, loadPolicy: loadPolicy, failureCause: failureCause)
        guard generation == speechGeneration else { return }
        await speak(text: text, resolution: resolution, ownerID: ownerID)
    }

    /// Speak on the route the Trust policy selects. An unreadable policy says
    /// so on the owning surface and reads nothing.
    public func speak(
        text: String,
        resolution: VoiceOutputModeResolution,
        ownerID: String? = nil
    ) async {
        switch resolution {
        case .openAI, .localConfigured:
            guard !text.isEmpty else { return }
            // Quiet silences current playback before declining the new utterance.
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
            if resolution == .openAI {
                await speakOpenAI(text: text)
            } else {
                speakLocal(text: text)
            }
        case .policyUnreadable(let reason):
            stop()
            guard !text.isEmpty, !VoicePreference.quiet() else { return }
            errorMessage = "Couldn't read the voice settings, so nothing was read aloud. \(reason)"
            errorOwnerID = ownerID
        }
    }

    public func isSpeaking(ownerID: String) -> Bool {
        isSpeaking && speechOwnerID == ownerID
    }

    public func consumeError(ownerID: String) -> String? {
        guard errorOwnerID == ownerID, let errorMessage else { return nil }
        self.errorMessage = nil
        errorOwnerID = nil
        return errorMessage
    }

    public func stop() {
        speechGeneration &+= 1
        pendingSynthesis?.cancel()
        pendingSynthesis = nil
        synthesizer?.stopSpeaking(at: .immediate)
        // Detach the delegate before releasing a player so it cannot publish stale playback state.
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isSpeaking = false
        speechOwnerID = nil
    }

    // MARK: Private

    private func speakLocal(text: String) {
        let utterance = GenerationTaggedUtterance(string: text, generation: speechGeneration)
        // An unset name leaves `voice` nil: the Mac's own chosen system voice.
        // A named voice this Mac lacks says so; it never reads in another one.
        let chosenVoice = VoicePreference.name()
        if !chosenVoice.isEmpty {
            guard let voice = AVSpeechSynthesisVoice(identifier: chosenVoice)
                ?? AVSpeechSynthesisVoice(language: chosenVoice) else {
                let owner = speechOwnerID
                stop()
                errorMessage = "The read-aloud voice \"\(chosenVoice)\" is not on this Mac, so nothing was read aloud. Set chat.voice_name to an installed voice, or leave it empty for the Mac's own voice."
                errorOwnerID = owner
                return
            }
            utterance.voice = voice
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
        let synthesis = Task {
            try Task.checkCancellation()
            return try await SwiftOpenAITTSClient.synthesizeChat(text: text, voice: { VoicePreference.cloudVoice() })
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
            let (audioData, unread) = try await withTaskCancellationHandler {
                try await synthesis.value
            } onCancel: {
                synthesis.cancel()
            }
            // Superseded by a concurrent stop()/speak() while awaiting — bail without touching shared state.
            guard generation == speechGeneration else { return }
            // Underlying synthesis may ignore cancellation and still return bytes.
            try Task.checkCancellation()
            // Detach any prior player's delegate so it cannot fire a stale callback.
            audioPlayer?.delegate = nil
            let player = try AVAudioPlayer(data: audioData)
            player.delegate = self
            audioPlayer = player
            guard player.play() else {
                errorMessage = "Audio playback could not start. Try reading aloud again."
                errorOwnerID = speechOwnerID
                stop()
                return
            }
            isSpeaking = true
            if unread > 0 {
                errorMessage = "Reading the first \(SwiftOpenAITTSClient.maxInputChars) characters aloud; the cloud voice takes no more in one request, so the last \(unread) will not be read."
                errorOwnerID = speechOwnerID
            }
        } catch {
            // Don't report/clear state if a concurrent stop()/speak() already superseded this call.
            guard generation == speechGeneration else { return }
            if Task.isCancelled || error is CancellationError {
                stop()
                return
            }
            errorMessage = OpenAIVoiceFailure.message(for: error, failureMessage: failureMessage)
            errorOwnerID = speechOwnerID
            isSpeaking = false
            speechOwnerID = nil
        }
    }


}
// Utterances carry their generation so stale synthesizer callbacks cannot clear newer speech.
private final class GenerationTaggedUtterance: AVSpeechUtterance {
    let generation: Int
    init(string: String, generation: Int) {
        self.generation = generation
        super.init(string: string)
    }
    required init?(coder: NSCoder) {
        // Never decoded — utterances are only created via init(string:generation:).
        return nil
    }
    // Copies preserve the generation so stale callbacks cannot clear newer speech.
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
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let generation = (utterance as? GenerationTaggedUtterance)?.generation
        Task { @MainActor in
            if let generation, generation != self.speechGeneration { return }
            self.isSpeaking = false
            self.speechOwnerID = nil
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        speechSynthesizer(synthesizer, didFinish: utterance)
    }
}

extension VoiceOutputController: AVAudioPlayerDelegate {
    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Delegate detachment cannot retract a callback already queued.
        let playerID = ObjectIdentifier(player)
        Task { @MainActor in
            guard self.audioPlayer.map(ObjectIdentifier.init) == playerID else { return }
            self.audioPlayer = nil
            self.isSpeaking = false
        }
    }

    nonisolated public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let playerID = ObjectIdentifier(player)
        if let error { Logger(subsystem: "com.nativeagent.app", category: "MultimodalTTS").error("[voice] audio decode failed: \(String(describing: error), privacy: .public)") }
        Task { @MainActor in
            guard self.audioPlayer.map(ObjectIdentifier.init) == playerID else { return }
            self.audioPlayer = nil
            self.errorOwnerID = self.speechOwnerID
            self.errorMessage = "The audio couldn't be played."
            self.isSpeaking = false
            self.speechOwnerID = nil
        }
    }
}

/// The Voice Auto-Read gate keeps "new reply" stable across SwiftUI re-renders.
extension VoiceOutputModeSelection {
    public static func autoReadDecision(
        enabled: Bool,
        sessionID: String,
        isSessionPrimed: Bool,
        lastMessage: (id: String, sessionId: String?, role: String, content: String)?,
        lastReadMessageID: String?
    ) -> (messageID: String, text: String)? {
        guard enabled else { return nil }
        guard isSessionPrimed else { return nil }
        guard let lastMessage else { return nil }

        let cleanSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSessionID.isEmpty else { return nil }
        if let messageSessionID = lastMessage.sessionId {
            guard messageSessionID.trimmingCharacters(in: .whitespacesAndNewlines) == cleanSessionID else {
                return nil
            }
        }
        guard lastMessage.role == "assistant" else { return nil }
        let text = lastMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard lastMessage.id != lastReadMessageID else { return nil }
        return (messageID: lastMessage.id, text: text)
    }
}
