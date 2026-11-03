import AVFoundation
import Foundation
import NativeAgentShared
import os
// Blueprint: | `MobileTalkAudio.swift` | Full-duplex voice-processing capture for an active talk session; timed on-device recognition and soft acknowledgment audio |

/// One audio session for the call's input, speech output and acknowledgment.
/// The engine stays running across turns, mute, app backgrounding and playback.
actor MobileTalkAudio {
    private var engine: AVAudioEngine?
    private var analyzer: MobileSpeechAnalyzer?
    private var tapped = false
    private var active = false
    private let muted = OSAllocatedUnfairLock(initialState: false)

    func start(names: [String], onLevel: @escaping @Sendable (Float, Double) -> Void,
               onResult: @escaping @Sendable (NativeAgentShared.SpeechUtterance, Double) -> Void,
               onSpeech: @escaping @Sendable (Bool, Double) -> Void,
               onError: @escaping @Sendable (String) -> Void) async throws {
        guard let locale = await MobileSpeechAnalyzer.supportedLocale() else {
            throw Self.failure("Talk needs on-device speech recognition for this device and language. Dictation and voice notes are available in Chat.")
        }
        try Task.checkCancellation()
        muted.withLock { $0 = false }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setAllowHapticsAndSystemSoundsDuringRecording(false)
        try session.setActive(true)
        active = true
        let engine = AVAudioEngine()
        self.engine = engine
        try engine.inputNode.setVoiceProcessingEnabled(true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Self.failure("No usable microphone route is connected.") }
        let analyzer = try await MobileSpeechAnalyzer(locale: locale, sourceFormat: format, names: names, conversation: true)
        guard !Task.isCancelled, self.engine === engine else { await analyzer.cancel(); throw CancellationError() }
        self.analyzer = analyzer
        analyzer.startConversation(onResult: onResult, onSpeech: onSpeech, onError: onError)
        let muted = self.muted
        let frames = OSAllocatedUnfairLock(initialState: Int64(0))
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            // Muting never feeds words into recognition. Keep the time base
            // advancing, using silence, so pre-mute results cannot become new speech.
            let isMuted = muted.withLock { $0 }
            let time = frames.withLock { frames in
                frames += Int64(buffer.frameLength)
                return Double(frames) / format.sampleRate
            }
            var rms: Float = 0
            if let channels = buffer.floatChannelData, buffer.frameLength > 0 {
                if isMuted {
                    for channel in 0..<Int(format.channelCount) {
                        channels[channel].update(repeating: 0, count: Int(buffer.frameLength))
                    }
                } else {
                    for i in 0..<Int(buffer.frameLength) { rms += channels[0][i] * channels[0][i] }
                    rms = sqrt(rms / Float(buffer.frameLength))
                }
            }
            do { try analyzer.append(buffer) }
            catch { onError(error.localizedDescription); return }
            onLevel(rms, time)
        }
        tapped = true
        engine.prepare()
        try engine.start()
    }

    nonisolated func setMuted(_ value: Bool) { muted.withLock { $0 = value } }

    func stop() throws {
        if tapped { engine?.inputNode.removeTap(onBus: 0) }
        tapped = false
        engine?.stop(); engine = nil
        let analyzer = self.analyzer
        self.analyzer = nil
        // Framework cancellation can finish independently; it cannot hold
        // the microphone, audio route or End control while awaiting results.
        Task { await analyzer?.cancel() }
        if active {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            active = false
        }
    }

    nonisolated static func failure(_ detail: String) -> NSError {
        NSError(domain: "NativeAgentTalk", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
    }

    /// A short, quiet sine cue; no system sound that might include a vibration.
    nonisolated static func acknowledgment() throws -> AVAudioPlayer {
        let rate = 24_000
        let count = 1_440
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(36 + count * 2)); ascii("WAVEfmt ")
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        ascii("data"); u32(UInt32(count * 2))
        for i in 0..<count {
            let envelope = sin(.pi * Double(i) / Double(count))
            let sample = Int16(1_800 * envelope * sin(2 * .pi * 660 * Double(i) / Double(rate)))
            u16(UInt16(bitPattern: sample))
        }
        return try AVAudioPlayer(data: data)
    }
}
