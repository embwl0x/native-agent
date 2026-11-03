import SwiftUI
import UIKit
import NativeAgentShared
// Blueprint: | `TalkModeView.swift` | The call face is their room: the chosen haze, their name in serif, a presence that breathes and lifts with whoever is speaking, each side's latest line, glass mute/end; Reduce Motion stills it, Reduce Transparency keeps it legible |

struct TalkModeView: View {
    let talk: TalkModeController
    @AppStorage(HazeColor.key) private var hazeRaw = HazeColor.defaultValue.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shades: [Color] { HazeColor(stored: hazeRaw).shades.map { Color(hex: $0) } }
    /// Whoever is speaking lifts the presence: her voice, or the live mic level.
    private var level: CGFloat {
        CGFloat(talk.isSpeaking ? talk.speechPulse : (talk.isMuted ? 0 : talk.inputLevel))
    }

    var body: some View {
        ZStack {
            AliveRoom(mood: talk.isSpeaking ? .replying : .idle)
            VStack(spacing: 0) {
                header.padding(.top, 28)
                Spacer(minLength: 8)
                presence
                Spacer(minLength: 8)
                captions.padding(.horizontal, 28)
                controls.padding(.top, 24).padding(.bottom, 16)
            }
        }
        .interactiveDismissDisabled()
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(talk.agentName)
                .font(.system(size: 34, weight: .regular, design: .serif))
            HStack(spacing: 6) {
                if let start = talk.startedAt { Text(start, style: .timer).monospacedDigit() }
                if talk.startedAt != nil, !talk.status.isEmpty { Text("·") }
                if !talk.status.isEmpty { Text(talk.status).lineLimit(1) }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// A breath every ~4.5 s, lifted by the speaking voice. Still under Reduce Motion.
    private var presence: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !(talk.isActive || talk.isStarting))) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breath = reduceMotion ? 0 : CGFloat((sin(t * 2 * .pi / 4.5) + 1) / 2)
            let lift = reduceMotion ? 0 : level
            ZStack {
                Circle()
                    .fill(shades[0].opacity(talk.isSpeaking ? 0.45 : 0.30))
                    .frame(width: 270, height: 270)
                    .blur(radius: 52)
                    .scaleEffect(1 + 0.06 * breath + 0.28 * lift)
                Circle()
                    .fill(RadialGradient(colors: [shades[2].opacity(0.95), shades[1].opacity(0.70)],
                                         center: .center, startRadius: 6, endRadius: 82))
                    .frame(width: 148, height: 148)
                    .blur(radius: 5)
                    .scaleEffect(1 + 0.03 * breath + 0.18 * lift)
                Circle()
                    .stroke(.white.opacity(talk.isSpeaking ? 0.32 : 0.14), lineWidth: 1)
                    .frame(width: 148, height: 148)
                    .scaleEffect(1 + 0.03 * breath + 0.18 * lift)
            }
            .opacity(talk.isActive || talk.isStarting ? 1 : 0.45)
        }
        .frame(height: 300)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }

    /// Each side's latest line, large enough to read at arm's length.
    private var captions: some View {
        VStack(alignment: .leading, spacing: 16) {
            line(talk.agentName, talk.agentCaption, emphasized: true)
            line("You", talk.userCaption, emphasized: false)
            if let error = talk.error {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
    }

    private func line(_ who: String, _ text: String, emphasized: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(who).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text.isEmpty ? "…" : text)
                .font(emphasized ? .title3 : .body)
                .foregroundStyle(emphasized ? .primary : .secondary)
                .lineLimit(4)
                .truncationMode(.head)
                .contentTransition(.opacity)
        }
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        GlassEffectContainer(spacing: 40) {
            HStack(spacing: 56) {
                Button { talk.toggleMute() } label: {
                    control(talk.isMuted ? "mic.slash.fill" : "mic.fill", label: talk.isMuted ? "Unmute" : "Mute")
                        .aliveGlass(in: Circle(), interactive: true)
                }
                .disabled(!talk.isActive)
                Button { talk.end() } label: {
                    control("phone.down.fill", label: talk.isActive || talk.isStarting ? "End" : "Back to chat")
                        .foregroundStyle(.white)
                        .aliveGlass(in: Circle(), interactive: true, tint: .red)
                }
                .disabled(talk.isEnding)
            }
        }
        .buttonStyle(.plain)
    }

    private func control(_ symbol: String, label: String) -> some View {
        Image(systemName: symbol)
            .font(.title2)
            .frame(width: 68, height: 68)
            .contentShape(Circle())
            .accessibilityLabel(label)
    }
}
