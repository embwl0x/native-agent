import SwiftUI
// Blueprint: | `DictationComposer.swift` | While you dictate or record, every word you have said, full width above the controls (grows to a cap, then scrolls and follows the end), and the live mic waveform; each redraws on its own, not the chat |

/// Everything said so far, at reading size. Grows with the words up to
/// `maxHeight`, then scrolls and stays on the newest line.
struct DictationTranscript: View {
    let input: VoiceInputController
    var maxHeight: CGFloat = 240
    @State private var height: CGFloat = 22

    private var mode: String {
        if input.isFinalizing { return "Finishing…" }
        guard input.isVoiceNote else { return "Dictating" }
        return input.isLocked ? "Voice note" : "Slide left to cancel · up to lock"
    }

    var body: some View {
        let words = input.transcript
        VStack(alignment: .leading, spacing: 4) {
            Text(mode)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AlivePalette.secondary)
            ScrollView {
                Text(words.isEmpty ? (input.statusText ?? "Listening…") : words)
                    .font(.body)
                    .foregroundStyle(words.isEmpty ? AlivePalette.secondary : AlivePalette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            }
            .frame(height: min(max(height, 22), maxHeight))
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .accessibilityElement(children: .combine)
    }
}

/// The live mic level as bars, newest on the right; empty slots are dots.
struct DictationWaveform: View {
    let input: VoiceInputController

    var body: some View {
        let levels = input.levels
        Canvas { context, size in
            let step: CGFloat = 5, bar: CGFloat = 2.5
            let slots = max(0, Int(size.width / step))
            let recent = levels.suffix(slots)
            let empty = slots - recent.count
            for slot in 0..<slots {
                let x = CGFloat(slot) * step
                guard slot >= empty else {
                    let dot = CGRect(x: x, y: (size.height - bar) / 2, width: bar, height: bar)
                    context.fill(Path(ellipseIn: dot), with: .color(AlivePalette.secondary.opacity(0.6)))
                    continue
                }
                let level = CGFloat(recent[recent.startIndex + slot - empty])
                let h = max(bar, level * size.height)
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: bar, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: bar / 2), with: .color(AlivePalette.text))
            }
        }
        .frame(height: 28)
        .accessibilityHidden(true)
    }
}

#if DEBUG
extension VoiceInputController {
    /// Screenshot fixture (-dictationSample): a long live transcript and a waveform; no audio, nothing sent.
    func showDictationSample() {
        guard ProcessInfo.processInfo.arguments.contains("-dictationSample"), !isListening else { return }
        isListening = true
        startedAt = Date().addingTimeInterval(-16)
        transcript = "So are you going to be able to tell when I'm jogging in the morning? I want to see everything I said "
            + "while I'm talking, all of it, not just the last two lines squeezed into a tiny box next to the buttons. "
            + "That's what makes a voice note feel good: reading it back before it goes. And if it runs long, it should "
            + "scroll and keep the newest words in view, the way the other apps do it."
        levels = (0..<96).map { Float(abs(sin(Double($0) * 0.7)) * 0.8 * Double($0 % 5 == 0 ? 0.3 : 1)) }
    }
}
#endif
