#if canImport(SwiftUI) && canImport(AVFoundation)
import Foundation
import SwiftUI
import Observation
@preconcurrency import AVFoundation
// Blueprint: | `VoiceNoteBubble.swift` | Shared Mac/phone voice-note face: original-audio waveform, duration, inline playback and expandable transcript with speaker ownership |

@MainActor @Observable
private final class VoiceNotePlayback: NSObject, AVAudioPlayerDelegate {
    var player: AVAudioPlayer?
    var peaks: [Float] = []
    var isPlaying = false
    var error: String?

    func prepare(url: URL) async throws {
        let peaks = try await Task.detached(priority: .utility) {
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return try (0..<48).map { index -> Float in
                file.framePosition = AVAudioFramePosition(Double(file.length - 1) * Double(index) / 48)
                try file.read(into: buffer, frameCount: min(1024, AVAudioFrameCount(file.length - file.framePosition)))
                guard let samples = buffer.floatChannelData?.pointee else { return 0 }
                return (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(samples[$1])) }
            }
        }.value
        try Task.checkCancellation()
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.prepareToPlay()
        self.player = player
        self.peaks = peaks
    }

    func toggle() {
        guard let player else { return }
        if isPlaying { player.pause(); isPlaying = false }
        else {
            isPlaying = player.play()
            if !isPlaying { error = "Audio playback could not start." }
        }
    }

    func stop() { player?.stop(); isPlaying = false }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.isPlaying = false
            if !flag { self?.error = "Audio playback was interrupted." }
        }
    }
}

public struct VoiceNoteBubble: View {
    private static let stopPlaybackNotification = Notification.Name("NativeAgent.voiceNote.stopPlayback")
    public static func stopPlayback() { NotificationCenter.default.post(name: stopPlaybackNotification, object: nil) }
    private let id: String
    private let transcript: String
    private let isOwn: Bool
    private let speaker: String
    private let resolveAudio: @Sendable () async throws -> URL
    @State private var playback = VoiceNotePlayback()
    @State private var expanded = false

    public init(id: String, transcript: String, isOwn: Bool, speaker: String,
                resolveAudio: @escaping @Sendable () async throws -> URL) {
        self.id = id; self.transcript = transcript; self.isOwn = isOwn
        self.speaker = speaker; self.resolveAudio = resolveAudio
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isOwn ? "Your voice note" : "\(speaker)’s voice note")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    if !playback.isPlaying { Self.stopPlayback() }
                    playback.toggle()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 40, height: 40)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(playback.player == nil)
                .accessibilityLabel(playback.isPlaying ? "Pause voice note" : "Play voice note")
                if playback.player != nil {
                    TimelineView(.animation(minimumInterval: 0.25, paused: !playback.isPlaying)) { _ in
                        let progress = (playback.player?.currentTime ?? 0) / max(0.01, playback.player?.duration ?? 0)
                        HStack(spacing: 8) {
                            HStack(spacing: 2) {
                                ForEach(Array(playback.peaks.enumerated()), id: \.offset) { index, peak in
                                    Capsule().fill(index < Int(progress * 48) ? Color.accentColor : Color.secondary.opacity(0.4))
                                        .frame(maxWidth: .infinity)
                                        .frame(height: max(3, CGFloat(sqrt(peak)) * 30))
                                }
                            }.frame(height: 32).accessibilityHidden(true)
                            Text(Self.duration(playback.isPlaying ? playback.player?.currentTime ?? 0 : playback.player?.duration ?? 0))
                                .font(.caption.monospacedDigit())
                        }
                    }
                } else if playback.error == nil {
                    ProgressView().controlSize(.small)
                    Text("Preparing audio…").font(.caption)
                } else {
                    Image(systemName: "waveform").foregroundStyle(.secondary)
                }
            }
            if let error = playback.error {
                Text("Audio unavailable: \(error)").font(.caption).foregroundStyle(.secondary)
            }
            Button { expanded.toggle() } label: {
                Text(transcript.isEmpty ? "Transcript unavailable" : transcript)
                    .font(.body).foregroundStyle(.primary)
                    .lineLimit(expanded ? nil : 2)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Transcript: \(transcript)")
            .accessibilityHint(expanded ? "Collapse transcript" : "Expand transcript")
        }
        .padding(12).frame(maxWidth: 360, alignment: .leading)
        .background(isOwn ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 16))
        .task(id: id) {
            playback.stop()
            do {
                let url = try await resolveAudio()
                try await playback.prepare(url: url)
            }
            catch { if !Task.isCancelled { playback.error = error.localizedDescription } }
        }
        .onDisappear { playback.stop() }
        .onReceive(NotificationCenter.default.publisher(for: Self.stopPlaybackNotification)) { _ in playback.stop() }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
#endif
