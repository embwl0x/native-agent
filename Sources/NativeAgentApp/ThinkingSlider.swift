import AppToolRuntime
import AppKit
import SwiftUI

/// The Thinking pane behind the composer's thinking word.
///
/// User, 2026-09-25: the system slider read as clunky — a hairline with ticks
/// and a small round knob, the level word below it, a note that looked like a
/// button. One row now says "Thinking  High", the track is one soft object
/// filled in the haze up to its knob, and the notes are quiet lines.
struct ThinkingPane: View {
    /// The level names this model supports, least thinking first.
    let levels: [String]
    @Binding var index: Int
    /// The word the composer row shows, so the pane and the row never disagree.
    let word: String
    /// The model's own default, named only while the pick differs from it.
    let modelDefault: (model: String, level: String)?
    let scope: String
    var focus: FocusState<Bool>.Binding

    @AppStorage(HazeColor.key) private var colorRaw = HazeColor.defaultValue.rawValue
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Thinking")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                // Leading-anchored, so a longer word grows into empty space and
                // nothing beside it moves.
                Text(word)
                    .font(ShellType.bodyMedium)
                    .foregroundStyle(wordTint)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            if levels.count > 1 {
                VStack(spacing: 6) {
                    ThinkingSlider(levels: levels, index: $index, focus: focus)
                        .accessibilityIdentifier("chat.composer.effort.slider")
                    // Agent's note 2 named the trade; the header now says it is
                    // thinking, so the ends say what each side buys.
                    HStack {
                        Text("Faster")
                        Spacer(minLength: 8)
                        Text("Deeper")
                    }
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.tertiary)
                    .accessibilityHidden(true)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(scope)
                if let modelDefault {
                    // The line keeps its room while hidden: a line that came
                    // and went made the card hop (User, 2026-09-15).
                    let same = modelDefault.level == word
                    Text("Default for \(modelDefault.model): \(modelDefault.level)")
                        .opacity(same ? 0 : 1)
                        .accessibilityHidden(same)
                }
            }
            .font(ShellType.label)
            .foregroundStyle(NativeAgentShell.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The level word wears the haze: its light shade on dark glass, its deep
    /// shade on light, so the word keeps body-text contrast in both.
    private var wordTint: Color {
        let haze = HazeColor(stored: colorRaw)
        return colorScheme == .dark ? haze.edgeLight : Color(nsColor: HazeColor.nsColor(haze.shades[1]))
    }
}

/// A thick track filled in the haze up to a pill knob. Dragging follows the
/// pointer and settles on the nearest level with a spring when let go; a click
/// on the track glides there; the arrow keys step with the same spring; each
/// level crossed under the pointer taps the trackpad.
struct ThinkingSlider: View {
    let levels: [String]
    @Binding var index: Int
    var focus: FocusState<Bool>.Binding

    @AppStorage(HazeColor.key) private var colorRaw = HazeColor.defaultValue.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the knob is drawn, in levels. Continuous while dragging; nil
    /// means "at `index`".
    @State private var position: CGFloat?
    @State private var drag: Drag?

    private struct Drag {
        /// The knob's offset from the pointer when the knob itself was taken;
        /// nil while a click on the track has not moved.
        var grab: CGFloat?
        /// The last level committed, for the crossing tap.
        var level: Int
    }

    private let knob = CGSize(width: 26, height: 16)
    private let settle = Animation.spring(response: 0.32, dampingFraction: 0.82)
    private let follow = Animation.interactiveSpring(response: 0.16, dampingFraction: 0.9)

    private var steps: CGFloat { CGFloat(max(levels.count - 1, 1)) }

    var body: some View {
        GeometryReader { geo in
            let span = max(geo.size.width - knob.width, 1)
            ThinkingTrack(
                dotCentres: levels.indices.map { centre(CGFloat($0), span: span) },
                x: centre(position ?? CGFloat(index), span: span),
                knob: knob,
                pressed: drag != nil,
                fill: hazeFill,
                dark: colorScheme == .dark
            )
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { changed($0, span: span) }
                    .onEnded { _ in ended() }
            )
        }
        .frame(height: 20)
        .focusable()
        .focused(focus)
        // The track draws its own focus: a haze ring on the knob, not a box.
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .onChange(of: index) { _, new in
            // Arrow keys, number keys and the word's own arrows all land here.
            guard drag == nil else { return }
            animate(settle) { position = CGFloat(new) }
        }
        .onChange(of: levels) { _, _ in position = nil }
        .accessibilityRepresentation {
            Slider(
                value: Binding(get: { Double(index) }, set: { index = Int($0.rounded()) }),
                in: 0...Double(steps),
                step: 1
            )
            .accessibilityLabel("Thinking level")
            .accessibilityValue(levels.indices.contains(index) ? levels[index] : "")
        }
    }

    private func centre(_ level: CGFloat, span: CGFloat) -> CGFloat {
        knob.width / 2 + level / steps * span
    }

    private var hazeFill: Color {
        Color(nsColor: HazeColor(stored: colorRaw).control(dark: colorScheme == .dark, labelled: false))
    }

    // MARK: - Motion

    private func changed(_ value: DragGesture.Value, span: CGFloat) {
        let pointer = min(max((value.location.x - knob.width / 2) / span * steps, 0), steps)
        let shown = position ?? CGFloat(index)
        if drag == nil {
            let onKnob = abs(value.startLocation.x - centre(shown, span: span)) <= knob.width / 2 + 2
            drag = Drag(grab: onKnob ? pointer - shown : nil, level: index)
        }
        if drag?.grab == nil, abs(value.translation.width) < 3 {
            // A click on the track: glide to the level under it.
            let target = pointer.rounded()
            animate(settle) { position = target }
            cross(to: Int(target))
            return
        }
        if drag?.grab == nil { drag?.grab = 0 }
        let next = min(max(pointer - (drag?.grab ?? 0), 0), steps)
        animate(follow) { position = next }
        cross(to: Int(next.rounded()))
    }

    private func ended() {
        let target = Int((position ?? CGFloat(index)).rounded())
        drag = nil
        index = target
        // Read back what was kept: a save in flight can refuse the change.
        animate(settle) { position = CGFloat(index) }
    }

    private func cross(to level: Int) {
        guard let current = drag, level != current.level else { return }
        drag?.level = level
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        index = level
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        let next = min(max(index + delta, 0), levels.count - 1)
        if next != index { index = next }
        return .handled
    }

    private func animate(_ animation: Animation, _ change: () -> Void) {
        withAnimation(reduceMotion ? nil : animation, change)
    }
}

/// The drawing, apart so it can read whether the slider around it has focus.
private struct ThinkingTrack: View {
    let dotCentres: [CGFloat]
    let x: CGFloat
    let knob: CGSize
    let pressed: Bool
    let fill: Color
    let dark: Bool

    @Environment(\.isFocused) private var isFocused
    private let trackHeight: CGFloat = 8

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(NativeAgentShell.hairline)
                .frame(height: trackHeight)
            dots(NativeAgentShell.tertiary.opacity(0.55))
            Capsule()
                .fill(fill)
                .frame(width: x, height: trackHeight)
            // The dots on the filled part are light, and the fill's own width
            // masks them, so they change colour exactly as it passes.
            dots(.white.opacity(0.6))
                .mask(alignment: .leading) { Rectangle().frame(width: x) }
            Capsule()
                .fill(.white)
                .overlay(Capsule().strokeBorder(.black.opacity(dark ? 0 : 0.08), lineWidth: 0.5))
                .frame(width: knob.width, height: knob.height)
                .shadow(color: .black.opacity(0.28), radius: 2.5, y: 1)
                .background {
                    Capsule()
                        .stroke(fill, lineWidth: 2)
                        .padding(-2.5)
                        .opacity(isFocused ? 1 : 0)
                }
                .scaleEffect(pressed ? 1.06 : 1)
                .offset(x: x - knob.width / 2)
        }
    }

    private func dots(_ color: Color) -> some View {
        ZStack(alignment: .leading) {
            ForEach(dotCentres.indices, id: \.self) { level in
                Circle()
                    .fill(color)
                    .frame(width: 3, height: 3)
                    .offset(x: dotCentres[level] - 1.5)
            }
        }
    }
}
