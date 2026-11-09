import ActivityKit
import AVFoundation
import Foundation
import Observation
import Speech
import UIKit
import NativeAgentShared
// Blueprint: | `TalkModeController.swift` | Session-bound hands-free talk; detector endpoints, final recognition, speech and explicit End |

@MainActor @Observable
final class TalkModeController: NSObject {
    static let shared = TalkModeController()
    private(set) var isPresented = false
    private(set) var isActive = false
    private(set) var isStarting = false
    private(set) var isEnding = false
    private(set) var isMuted = false
    private(set) var isSpeaking = false
    private(set) var startedAt: Date?
    private(set) var userCaption = ""
    private(set) var agentCaption = ""
    private(set) var inputLevel: Float = 0
    private(set) var speechPulse: Float = 0
    private(set) var status = ""
    private(set) var error: String?
    var agentName: String { iCloudSyncEngine.shared.agentDisplayName }

    @ObservationIgnored private let audio = MobileTalkAudio()
    @ObservationIgnored private var synthesizer: AVSpeechSynthesizer?
    @ObservationIgnored private var cue: AVAudioPlayer?
    @ObservationIgnored private var client: MacBridgeClient?
    @ObservationIgnored private var controls = ChatRuntimeControls.defaults
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var callID: UUID?
    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private var activity: Activity<PhoneTalkAttributes>?
    @ObservationIgnored private var activityUpdate: Task<Void, Never>?
    @ObservationIgnored private var segments: [Double: [SpeechUtterance.Hypothesis.Segment]] = [:]
    @ObservationIgnored private var audioTime: Double = 0
    @ObservationIgnored private var sentThrough: Double = 0
    /// Recognizer time fences sent turns: a result starting before the last sent word end settles that turn, never the next.
    @ObservationIgnored private var submittedThrough: Double = 0
    @ObservationIgnored private var volatileRegions: Set<Double> = []
    @ObservationIgnored private var endpointThrough: Double?
    @ObservationIgnored private var heardSpeech = false
    @ObservationIgnored private var isFinalizing = false
    @ObservationIgnored private var runs: [String: ReplySpeech] = [:]
    @ObservationIgnored private var utterances: Set<ObjectIdentifier> = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private struct ReplySpeech {
        var consumed = ""
        var suppressed = false
        var terminal = false
    }

    override private init() {
        super.init()
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if name == AVAudioSession.interruptionNotification,
                   (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) != AVAudioSession.InterruptionType.began.rawValue { return }
                Task { @MainActor in
                    guard let self, self.isActive || self.isStarting else { return }
                    self.end(reason: "Talk ended because the audio session was interrupted. Start talk again when you’re ready.")
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
            queue: .main) { [weak self] note in
            guard (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable
                .rawValue else { return }
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.end(reason: "The microphone or headphones disconnected. Start talk again on the new audio route.")
            }
        })
    }

    func begin(client: MacBridgeClient, controls: ChatRuntimeControls) {
        guard !isPresented, !isEnding else { return }
        isPresented = true; isStarting = true; error = nil
        status = "Preparing to listen…"
        userCaption = ""; agentCaption = ""; segments = [:]
        retainOutstandingRuns()
        sentThrough = 0; submittedThrough = 0; volatileRegions = []; audioTime = 0; endpointThrough = nil
        heardSpeech = false; isMuted = false; isFinalizing = false
        startedAt = nil; self.client = client; self.controls = controls
        VoiceNoteBubble.stopPlayback()
        ChatStore.shared.attachReplyReceiver(using: client)
        let id = UUID(); callID = id
        startup = Task { [weak self] in
            guard let self else { return }
            do {
                await ChatStore.shared.restorationTask?.value
                try MobileIntentRuntime.prepare()
                await iCloudSyncEngine.shared.refreshLightweightSnapshots()
                try checkStarting(id)
                guard !ChatStore.shared.isSwitchingSession else {
                    throw MobileTalkAudio.failure("Wait for the conversation to finish opening, then start talk.")
                }
                let authorization = await VoiceInputController.requestSpeechAuthorization()
                try checkStarting(id)
                guard authorization == .authorized else {
                    throw MobileTalkAudio.failure(VoiceInputAuthorizationPresentation.speechFailureMessage(for: authorization))
                }
                guard await AVAudioApplication.requestRecordPermission() else { throw MobileTalkAudio.failure(VoicePresentation.deniedMicrophoneMessage()) }
                try checkStarting(id)
                _ = try Self.preferredVoice()
                if ChatStore.shared.selectedSessionID == nil {
                    ChatStore.shared.setSelectedSessionID(MobileIntentRuntime.phoneConversationID)
                }
                sessionID = ChatStore.shared.selectedSessionID
                ChatStore.shared.onTalkReply = { [weak self] run, text, terminal, failure in
                    self?.receiveReply(run: run, text: text, terminal: terminal, failure: failure)
                }
                ChatStore.shared.onTalkRunRenamed = { [weak self] previous, current in
                    guard let self, let speech = self.runs.removeValue(forKey: previous) else { return }
                    self.runs[current] = speech
                }
                ChatStore.shared.onTalkSessionChange = { [weak self] in
                    self?.end(reason: "Talk ended because the conversation changed. Its messages remain in that chat.")
                }
                let names = [agentName, iCloudSyncEngine.shared.personality?.userName ?? ""].filter { !$0.isEmpty }
                try await MobileDictation.shared.prepareForTalk()
                try checkStarting(id)
                // Emit the start haptic before opening capture so the microphone cannot record it.
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                try await audio.start(names: names, onLevel: { [weak self] level, time in
                    Task { @MainActor in guard self?.callID == id else { return }; self?.receiveLevel(level, time: time) }
                }, onResult: { [weak self] result, region in
                    Task { @MainActor in guard self?.callID == id else { return }; self?.receiveWords(result, region: region) }
                }, onSpeech: { [weak self] speech, through in
                    Task { @MainActor in
                        guard let self, self.callID == id, self.isActive, !self.isMuted,
                              through > self.sentThrough + 0.001 else { return }
                        if speech {
                            self.heardSpeech = true
                            self.endpointThrough = nil
                            self.isFinalizing = false
                            self.bargeIn()
                        } else if self.heardSpeech {
                            self.endpointThrough = through
                            self.finalizeTurn()
                        }
                    }
                }, onError: { [weak self] detail in
                    Task { @MainActor in guard self?.callID == id else { return }; self?.end(reason: "Speech recognition stopped: \(detail)") }
                })
                try checkStarting(id)
                isStarting = false; isActive = true; startedAt = Date()
                status = iCloudSyncEngine.shared.voicePreference?.quiet == true ? "Listening · Quiet mode: captions only" : "Listening"
                updateActivity(start: true)
                // Keep the receive/presence owner awake in background only for this active audio session.
                iCloudBridge.shared.startForegroundReceiving()
            } catch {
                guard callID == id else { return }
                end(reason: error.localizedDescription)
            }
        }
    }

    private func checkStarting(_ id: UUID) throws {
        try Task.checkCancellation()
        guard callID == id, isStarting else { throw CancellationError() }
    }

    static func preferredVoice() throws -> AVSpeechSynthesisVoice? {
        guard let preference = iCloudSyncEngine.shared.voicePreference else {
            throw MobileTalkAudio.failure("The Mac’s voice preference has not synced. Open NativeAgent on the Mac and sync this phone before talking.")
        }
        if preference.quiet { return nil }
        guard let name = preference.nativeName, let language = preference.nativeLanguage else {
            throw MobileTalkAudio.failure(
                "The Mac’s voice preference does not name an available Apple voice. Choose an installed voice on the Mac and sync again.")
        }
        guard let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.name == name && $0.language == language }) else {
            throw MobileTalkAudio.failure("""
                The Mac’s voice “\(name)” is not installed on this iPhone. Download that voice in iPhone Settings → \
                Accessibility → Read & Speak → Voices, then start talk again.
                """)
        }
        return voice
    }

    private func receiveLevel(_ level: Float, time: Double) {
        guard isActive else { return }
        audioTime = time
        inputLevel = isMuted ? 0 : min(1, level * 16)
    }

    private func receiveWords(_ utterance: SpeechUtterance, region: Double) {
        guard isActive, !isMuted, region + 0.001 >= submittedThrough else { return }
        let incoming = utterance.hypotheses.first?.segments ?? []
        let fresh = incoming.filter { $0.timestamp + $0.duration > sentThrough + 0.001 }
        guard !fresh.isEmpty else { return }
        // Replace by recognizer region start, not first-word time: final word timing can shift and otherwise duplicate its draft.
        segments = segments.filter { $0.key < region }
        segments[region] = fresh
        volatileRegions = volatileRegions.filter { $0 < region }
        if !utterance.isFinal { volatileRegions.insert(region) }
        userCaption = currentWords
        guard !userCaption.isEmpty else { return }
        heardSpeech = true
        bargeIn()
        if isFinalizing, volatileRegions.isEmpty { submitTurn() }
    }

    private var currentWords: String {
        segments.sorted { $0.key < $1.key }.flatMap(\.value).map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A detector endpoint holds submission until every recognized region is final.
    private func finalizeTurn() {
        guard !isFinalizing else { return }
        isFinalizing = true
        if !currentWords.isEmpty, volatileRegions.isEmpty { submitTurn() }
        else { status = "Waiting for final recognition · End to cancel"; updateActivity() }
    }

    private func submitTurn() {
        guard let endpointThrough, volatileRegions.isEmpty else { return }
        isFinalizing = false
        let text = currentWords
        let through = segments.values.flatMap { $0 }.map { $0.timestamp + $0.duration }.max() ?? sentThrough
        // Retire settled regions only; late results for a sent draft must retain just words beyond the sent turn.
        sentThrough = max(endpointThrough, through); submittedThrough = through
        self.endpointThrough = nil
        segments = [:]; heardSpeech = false; volatileRegions = []
        guard !text.isEmpty else { status = "No words recognized · Listening"; return }
        guard let client,
            ChatStore.shared.selectedSessionID == sessionID else { end(reason: "The conversation changed before your words could be sent."); return }
        let store = ChatStore.shared
        let before = Set(store.queuedSends.map(\.id))
        guard store.send(text: text, client: client, controls: controls, emitHaptic: false) else {
            end(reason: store.errorBanner ?? "Your words could not be saved to this conversation."); return
        }
        for send in store.queuedSends where !before.contains(send.id) { runs[send.id.uuidString] = ReplySpeech() }
        userCaption = text
        if iCloudSyncEngine.shared.voicePreference?.quiet != true {
            do { cue = try MobileTalkAudio.acknowledgment(); cue?.play() }
            catch { self.error = "Your message was saved, but the acknowledgment sound could not play: \(error.localizedDescription)" }
        }
        status = "Sent · Waiting for \(agentName) · You can keep talking or end"
        updateActivity()
    }

    private func receiveReply(run: String, text: String, terminal: Bool, failure: String?) {
        guard isActive, var reply = runs[run], !reply.terminal else { return }
        guard !reply.suppressed else { reply.terminal = terminal; runs[run] = reply; return }
        agentCaption = text
        if let failure {
            reply.terminal = true; runs[run] = reply
            stopSpeech()
            status = "Listening"; error = failure
            updateActivity(); return
        }
        let consumedEnd: String.Index?
        if text.hasPrefix(reply.consumed) {
            consumedEnd = text.index(text.startIndex, offsetBy: reply.consumed.count)
        } else if terminal {
            // Keep queued speech when final assembly changes only edge whitespace or paragraph seams.
            consumedEnd = Self.consumedPrefixEnd(in: text, matching: reply.consumed)
        } else {
            consumedEnd = nil
        }
        guard let consumedEnd else {
            reply.suppressed = true; runs[run] = reply; stopSpeech()
            error = "The reply changed after speech began. Read its updated wording in Chat."
            return
        }
        reply.consumed = String(text[..<consumedEnd])
        var remainder = String(text[consumedEnd...])
        while let end = Self.sentenceEnd(remainder, terminal: terminal) {
            let sentence = String(remainder[..<end])
            reply.consumed += sentence
            remainder = String(remainder[end...])
            enqueueSpeech(sentence)
        }
        reply.terminal = terminal; runs[run] = reply
        if terminal && utterances.isEmpty { status = "Listening"; updateActivity() }
    }

    private static func consumedPrefixEnd(in text: String, matching consumed: String) -> String.Index? {
        var index = text.startIndex
        for character in consumed where !character.isWhitespace {
            while index < text.endIndex && text[index].isWhitespace { text.formIndex(after: &index) }
            guard index < text.endIndex, text[index] == character else { return nil }
            text.formIndex(after: &index)
        }
        return index
    }

    private static func sentenceEnd(_ text: String, terminal: Bool) -> String.Index? {
        for index in text.indices where ".!?。！？\n".contains(text[index]) {
            let next = text.index(after: index)
            if next == text.endIndex || text[next].isWhitespace { return next }
        }
        return terminal && !text.isEmpty ? text.endIndex : nil
    }

    private func enqueueSpeech(_ sentence: String) {
        guard iCloudSyncEngine.shared.voicePreference?.quiet != true else { return }
        do {
            let voice = try Self.preferredVoice()
            if synthesizer == nil {
                let synth = AVSpeechSynthesizer(); synth.delegate = self
                synth.usesApplicationAudioSession = true
                synthesizer = synth
            }
            let spoken = sentence.replacingOccurrences(of: "[*`#]", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spoken.isEmpty else { return }
            let utterance = AVSpeechUtterance(string: spoken)
            utterance.voice = voice; utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterances.insert(ObjectIdentifier(utterance))
            synthesizer?.speak(utterance)
        } catch { self.error = error.localizedDescription }
    }

    private func bargeIn() {
        let interrupted = runs.keys.filter { runs[$0]?.terminal == false && runs[$0]?.suppressed == false }
        guard !utterances.isEmpty || !interrupted.isEmpty else { return }
        for key in runs.keys { runs[key]?.suppressed = true }
        stopSpeech()
        status = "Listening to you"
        updateActivity()
        let activeRuns = interrupted.filter { ChatStore.shared.activeTurnRunIDs.contains($0) }
        guard !activeRuns.isEmpty, let client else { return }
        let session = sessionID
        Task {
            do { try await client.cancelChat(sessionID: session, runIDs: activeRuns) }
            catch { self.error = "The agent's voice stopped. The Mac has not confirmed stopping its reply: \(error.localizedDescription)" }
        }
    }

    private func stopSpeech() {
        utterances = []; synthesizer?.stopSpeaking(at: .immediate)
        isSpeaking = false; speechPulse = 0
    }

    func toggleMute() {
        guard isActive else { return }
        isMuted.toggle(); endpointThrough = nil
        isFinalizing = false; segments = [:]; heardSpeech = false; volatileRegions = []; sentThrough = audioTime
        status = isMuted ? "Muted" : "Listening"
        let value = isMuted
        audio.setMuted(value)
        updateActivity()
    }

    func quietPreferenceChanged() {
        guard isActive, iCloudSyncEngine.shared.voicePreference?.quiet == true else { return }
        stopSpeech(); cue?.stop()
        status = isMuted ? "Muted" : "Listening · Quiet mode: captions only"
        updateActivity()
    }

    func end(reason: String? = nil) {
        guard !isEnding else { return }
        guard isActive || isStarting else { if reason == nil { isPresented = false }; return }
        isEnding = true
        let hadAudio = isActive
        callID = nil; isActive = false; isStarting = false
        startup?.cancel()
        stopSpeech(); cue?.stop(); cue = nil
        for key in runs.keys { runs[key]?.suppressed = true }
        retainOutstandingRuns()
        ChatStore.shared.onTalkReply = nil; ChatStore.shared.onTalkSessionChange = nil
        ChatStore.shared.onTalkRunRenamed = nil
        // End closes this call's input/output; accepted messages and Mac work remain with Chat.
        activityUpdate?.cancel()
        let endingCallID = activity?.attributes.callID; activity = nil
        Task {
            do { try await audio.stop() }
            catch { self.error = "Talk ended, but audio release failed: \(error.localizedDescription)" }
            if hadAudio { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
            if let endingCallID { Task { await Self.endTalkActivities(callID: endingCallID) } }
            if UIApplication.shared.applicationState != .active { iCloudBridge.shared.stopForegroundReceiving() }
            isEnding = false; status = "Talk ended"
            if let reason { error = reason }
            else if let error { ChatStore.shared.errorBanner = error }
            isPresented = reason != nil
        }
    }

    private func updateActivity(start: Bool = false) {
        guard isActive, let startedAt, let callID else { return }
        let state = PhoneTalkAttributes.ContentState(muted: isMuted, status: status)
        if start, ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                activity = try Activity.request(attributes: PhoneTalkAttributes(callID: callID.uuidString, agentName: agentName, startedAt: startedAt),
                    content: ActivityContent(state: state, staleDate: nil), pushType: nil)
            } catch { self.error = "Talk is active, but its Live Activity could not start: \(error.localizedDescription)" }
        } else if activity != nil {
            activityUpdate?.cancel()
            let id = callID.uuidString
            activityUpdate = Task { await Self.updateTalkActivity(callID: id, state: state) }
        }
    }

    // Activity is not Sendable; look it up by ID inside concurrent helpers instead of crossing isolation.
    @concurrent nonisolated static func endTalkActivities(callID: String?) async {
        for activity in Activity<PhoneTalkAttributes>.activities where callID == nil || activity.attributes.callID == callID {
            await activity.end(ActivityContent(state: .init(muted: true, status: "Ended"), staleDate: nil), dismissalPolicy: .immediate)
        }
    }

    @concurrent nonisolated private static func updateTalkActivity(callID: String, state: PhoneTalkAttributes.ContentState) async {
        for activity in Activity<PhoneTalkAttributes>.activities where activity.attributes.callID == callID {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    func acceptsCommand(callID: String) -> Bool { isActive && self.callID?.uuidString == callID }

    /// Use run identity to keep late call replies text-only after End, even when Chat read-aloud is enabled.
    func consumeEndedReply(_ run: String?) -> Bool {
        guard let run, runs[run] != nil else { return false }
        if !isActive { runs.removeValue(forKey: run) }
        return true
    }

    private func retainOutstandingRuns() {
        let store = ChatStore.shared
        let pending = Set(store.pendingExchanges.keys).union(store.queuedSends.map { $0.id.uuidString })
        runs = runs.filter { pending.contains($0.key) }
    }
}

extension TalkModeController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.isActive, self.utterances.contains(id) else { return }
            self.isSpeaking = true; self.status = "\(self.agentName) is speaking"; self.updateActivity()
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        let pulse = min(1, Float(characterRange.length) / 10)
        Task { @MainActor in guard self.utterances.contains(id) else { return }; self.speechPulse = pulse }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.utterances.remove(id) != nil, self.utterances.isEmpty else { return }
            self.isSpeaking = false; self.speechPulse = 0
            self.status = self.isMuted ? "Muted" : "Listening"; self.updateActivity()
        }
    }
}
