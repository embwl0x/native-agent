import SwiftUI
import NativeAgentShared
import UIKit
// Blueprint: | `AliveControls.swift` | Status lights, actions, search, glass controls and haze swatches |

/// The agent's small light, always in the haze colour: steady when here, a
/// stronger glow while working or while something waits on you (the Mac rule:
/// "needs you" follows the haze), grey when the Mac cannot be reached.
struct AliveStatusDot: View {
    enum State { case here, working, waiting, away }
    let state: State
    @AppStorage(HazeColor.key) private var colorRaw = HazeColor.defaultValue.rawValue
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let color: Color = state == .away
            ? AlivePalette.secondary.opacity(0.6)
            : HazeColor(stored: colorRaw).control(dark: colorScheme == .dark, labelled: false)
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .shadow(color: color.opacity(state == .away ? 0 : 0.7), radius: state == .here ? 4 : 7)
            .accessibilityHidden(true)
    }
}

/// "Working": a small pulsing dot in the haze colour.
struct HazePulse: View {
    @AppStorage(HazeColor.key) private var colorRaw = HazeColor.defaultValue.rawValue
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        PulsingDot(color: HazeColor(stored: colorRaw).control(dark: colorScheme == .dark, labelled: false), size: 7)
            .accessibilityHidden(true)
    }
}

// MARK: - States and actions

/// "Waiting on you": a haze dot sat on the first line's baseline.
struct AliveWaitingDot: View {
    @AppStorage(HazeColor.key) private var colorRaw = HazeColor.defaultValue.rawValue
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let color = HazeColor(stored: colorRaw).control(dark: colorScheme == .dark, labelled: false)
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.6), radius: 4)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            .accessibilityHidden(true)
    }
}

/// Empty, unpaired, syncing: a serif line, one sentence, at most one way on.
struct AliveCalmState: View {
    let title: String
    let line: String
    var actionTitle: String? = nil
    var actionHint: String? = nil
    var showsProgress = false
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if showsProgress { ProgressView().controlSize(.small) }
                Text(title)
                    .font(.system(.title2, design: .serif))
                    .foregroundStyle(AlivePalette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(line)
                .font(.body)
                .lineSpacing(3)
                .foregroundStyle(AlivePalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .alivePrimaryButton()
                    .accessibilityHint(actionHint ?? "")
                    .padding(.top, 8)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aliveCard()
        .accessibilityElement(children: .contain)
    }
}

extension View {
    /// The one primary action: a capsule filled with the haze's deep shade,
    /// where a white label clears 5:1.
    func alivePrimaryButton() -> some View {
        buttonStyle(.borderedProminent).buttonBorderShape(.capsule).hazeTinted(labelled: true)
    }

    /// Every other action: a quiet neutral capsule.
    func aliveSecondaryButton() -> some View {
        buttonStyle(.bordered).buttonBorderShape(.capsule).tint(AlivePalette.text)
    }
}

/// Buttons in a row at their own width; a column when they cannot fit.
struct AliveActionRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if !typeSize.isAccessibilitySize {
                HStack(spacing: 8) { content() }
                    .fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 8) { content() }
        }
        .labelStyle(.titleOnly)
        .font(.subheadline.weight(.semibold))
        .controlSize(.regular)
    }
}

/// A quiet track, the chosen side washed in the haze (its one job here is
/// "selected").
struct AliveSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String

    var body: some View {
        // Use the native segmented control.
        Picker("", selection: $selection) {
            ForEach(options, id: \.self) { Text(title($0)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// The floating search: glass, because it is a control over the list.
struct AliveSearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AlivePalette.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .font(.body)
                .foregroundStyle(AlivePalette.text)
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AlivePalette.secondary)
                        .frame(width: 32, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 50)
        .aliveGlass(in: Capsule(), interactive: true)
    }
}

/// A page-level note under the header, in secondary text: what is true, and
/// at most one quiet way on. The snapshot freshness note wears it.
struct AliveStatusNote: View {
    var systemImage = "clock"
    let text: String
    var actionTitle: String? = nil
    var actionHint: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    AliveNoteAction(title: actionTitle, hint: actionHint, action: action)
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(AlivePalette.secondary)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A page note's one way on, alone or under the note's sentence.
struct AliveNoteAction: View {
    let title: String
    var hint: String? = nil
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(.footnote.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .hazeTinted()
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityHint(hint ?? "")
    }
}

// MARK: - Glass for floating controls

extension View {
    /// Liquid Glass on the functional layer only (composer, floating buttons).
    /// Uses `.regular` glass, with opaque chrome for Reduce Transparency.
    /// Never put this on content or on something already sitting on glass.
    func aliveGlass<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(AliveGlass(shape: shape, interactive: interactive, tint: tint))
    }

    /// Keep the navigation title for VoiceOver and the app switcher, but do
    /// not draw it: the page's serif header says it. Below iOS 18 it shows.
    @ViewBuilder func aliveHiddenTitle() -> some View {
        if #available(iOS 18.0, *) { toolbar(removing: .title) } else { self }
    }

    /// Tint ONE control with the chosen haze. Per control, never a page.
    func hazeTinted(labelled: Bool = false) -> some View { modifier(HazeControlTint(labelled: labelled)) }
}

private struct AliveGlass<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    let tint: Color?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(tint ?? NativeAgentMobileTheme.Colors.navigationGlass, in: shape)
                .overlay(shape.stroke(NativeAgentMobileTheme.Colors.hairline, lineWidth: 1))
        } else {
            content.glassEffect(glass, in: shape)
        }
    }

    private var glass: Glass {
        var glass = NativeAgentMobileTheme.plateGlass
        if let tint { glass = glass.tint(tint) }
        return interactive ? glass.interactive() : glass
    }
}

private struct HazeControlTint: ViewModifier {
    let labelled: Bool
    @AppStorage(HazeColor.key) private var colorRaw = HazeColor.defaultValue.rawValue
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.tint(HazeColor(stored: colorRaw).control(dark: colorScheme == .dark, labelled: labelled))
    }
}

/// The seven haze swatches, the chosen one ringed. Same palette as the Mac.
struct HazeSwatches: View {
    @AppStorage(HazeColor.key) private var colorRaw = HazeColor.defaultValue.rawValue

    var body: some View {
        let selected = HazeColor(stored: colorRaw)
        // 7 × 36 + 6 × 2 = 264pt: fits a Settings row on the narrowest iPhone.
        HStack(spacing: 2) {
            ForEach(HazeColor.allCases) { color in
                Button {
                    colorRaw = color.rawValue
                } label: {
                    Circle()
                        .fill(color.swatch)
                        .frame(width: 26, height: 26)
                        .padding(4)
                        .overlay {
                            Circle().strokeBorder(color == selected ? AlivePalette.text : .clear, lineWidth: 2)
                        }
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(color.name)
                .accessibilityAddTraits(color == selected ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .sensoryFeedback(.selection, trigger: colorRaw)
    }
}
