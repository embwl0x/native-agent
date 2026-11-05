import SwiftUI
import Foundation
import NativeAgentShared
import UIKit
// Blueprint: | `AliveControls.swift` | Status lights, actions, search, glass controls and haze swatches |

/// Reserve haze for presence, work and decisions; unreachable Macs use grey.
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

// MARK: - States and actions

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

/// Empty, unpaired and syncing states offer at most one recovery action.
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
    /// The primary action uses the deep haze shade so its white label clears 5:1.
    func alivePrimaryButton() -> some View {
        buttonStyle(.borderedProminent).buttonBorderShape(.capsule).hazeTinted(labelled: true)
    }

    /// Keep secondary actions neutral so the primary action retains emphasis.
    func aliveSecondaryButton() -> some View {
        buttonStyle(.bordered).buttonBorderShape(.capsule).tint(AlivePalette.text)
    }
}

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

/// Reserve the haze wash for the selected segment.
struct AliveSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.self) { Text(title($0)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// Floating search uses glass because it sits over content.
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

/// Page notes state one fact and offer at most one recovery action.
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
    /// Glass belongs only to floating controls; Reduce Transparency needs opaque chrome. Never layer glass on content or glass.
    func aliveGlass<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(AliveGlass(shape: shape, interactive: interactive, tint: tint))
    }

    /// Retain the navigation title for VoiceOver and the app switcher; the visible serif header already names the page.
    @ViewBuilder func aliveHiddenTitle() -> some View {
        toolbar(removing: .title)
    }

    /// Apply haze tint per control so a page cannot tint unrelated content.
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

struct HazeSwatches: View {
    @MainActor static var settingControl: PhoneLocalSetting {
        PhoneLocalSetting(id: "phone.haze_color", label: "iPhone haze", type: "choice",
            choices: HazeColor.allCases.map(\.rawValue), read: {
                guard let saved = UserDefaults.standard.object(forKey: HazeColor.key) else { return HazeColor.defaultValue.rawValue }
                guard let raw = saved as? String, HazeColor(stored: raw) != .unavailable else {
                    throw PhoneLocalSetting.failure("The saved iPhone haze is invalid. Choose a haze in iPhone NativeAgent Settings.")
                }
                return raw
            }, write: { raw, authority in
                guard HazeColor.allCases.contains(where: { $0.rawValue == raw }) else { throw PhoneLocalSetting.failure("Choose a listed haze.") }
                try authority.check()
                UserDefaults.standard.set(raw, forKey: HazeColor.key)
            })
    }
    @AppStorage(HazeColor.key) private var colorRaw = HazeColor.defaultValue.rawValue

    var body: some View {
        let selected = HazeColor(stored: colorRaw)
        // 7 × 36 + 6 × 2 = 264pt: fits a Settings row on the narrowest iPhone.
        VStack(alignment: .leading, spacing: 6) {
        if selected == .unavailable {
            Text("The saved color is unsupported. Choose a color to repair this setting.")
                .font(.footnote).foregroundStyle(AlivePalette.secondary)
        }
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
}
