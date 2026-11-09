import NativeAgentShared

// Blueprint: | `WindowHaze.swift` | Mac window haze palette, controls and shared `HazeView` presentation |
// Core Animation avoids per-frame main-thread work; cap combined disc overlap at 0.44 to preserve contrast.

import AppKit
import SwiftUI

// MARK: - The colour setting

extension HazeColor {
    var base: Color { swatch }

    var edgeLight: Color {
        switch self {
        case .unavailable: .clear
        case .teal: Color(hex: 0xA0F0E4)
        case .blue: Color(hex: 0xAAC8FF)
        case .violet: Color(hex: 0xCDB9FF)
        case .rose: Color(hex: 0xFFBED2)
        case .amber: Color(hex: 0xFFDCAA)
        case .forest: Color(hex: 0xBEF0C8)
        case .graphite: Color(hex: 0xDCE1EB)
        }
    }

    var swatch: Color { Color(hex: shades[0]) }

    /// Deepen root ink in light rooms so the dark swatch retains contrast.
    func windowTint(dark: Bool) -> Color {
        guard !dark else { return base }
        let deep = NSColor(Color(hex: shades[1]))
        return Color(nsColor: NSColor(srgbRed: deep.redComponent * 0.7,
                                     green: deep.greenComponent * 0.7,
                                     blue: deep.blueComponent * 0.7, alpha: 1))
    }

    /// Use deep shades under white labels for at least 5:1 contrast; base teal and amber reach only 3.1:1.
    /// Tracks need base shades in dark rooms (at least 3.4:1) and deep shades in light rooms (over 4.5:1).
    /// Light-room base teal and amber reach only 2.8:1.
    func control(dark: Bool, labelled: Bool) -> NSColor {
        NSColor(Color(hex: dark && !labelled ? shades[0] : shades[1]))
    }
}

// MARK: - Controls wear the haze

extension View {
    /// Tint one control's on state with haze; page-level tint accents everything.
    func hazeTinted(_ kind: HazeControlKind = .toggle) -> some View { modifier(HazeControlTint(kind: kind)) }
}

enum HazeControlKind { case toggle, segments, button }

private struct HazeControlTint: ViewModifier {
    var kind: HazeControlKind
    @FacePreference(HazeColor.key) private var colorRaw = HazeColor.defaultValue.rawValue
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        FacePreferences(keys: [HazeColor.key]) { preferenceContent(content) }
    }

    @ViewBuilder private func preferenceContent(_ content: Content) -> some View {
        let color = HazeColor(stored: colorRaw).control(dark: colorScheme == .dark, labelled: kind != .toggle)
        content
            .tint(Color(nsColor: color))
            // tint does not reach AppKit's selected segment; set the native control colour directly.
            .background { if kind == .segments { SegmentBezelTint(color: color) } }
    }
}

/// Touch only NSSegmentedControl so mounting behind another control remains inert.
private struct SegmentBezelTint: NSViewRepresentable {
    var color: NSColor

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.color = color
        view.apply()
    }

    final class Probe: NSView {
        var color: NSColor?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func apply() {
            guard let color, window != nil else { return }
            let mine = convert(bounds, to: nil)
            var ancestor = superview
            for _ in 0..<4 {
                guard let view = ancestor else { return }
                if let control = Self.segmented(in: view, over: mine) {
                    if control.selectedSegmentBezelColor != color { control.selectedSegmentBezelColor = color }
                    return
                }
                ancestor = view.superview
            }
        }

        private static func segmented(in view: NSView, over rect: NSRect) -> NSSegmentedControl? {
            for sub in view.subviews {
                if let control = sub as? NSSegmentedControl,
                   control.convert(control.bounds, to: nil).intersects(rect) { return control }
                if let found = segmented(in: sub, over: rect) { return found }
            }
            return nil
        }
    }
}

// MARK: - The window's haze

/// Respect Reduce Transparency by drawing nothing and Reduce Motion by holding still.
struct WindowHaze: View {
    /// Optional lookup lets model-free snapshot hosts draw a still haze without starting a runtime.
    @Environment(AppModel.self) private var appModel: AppModel?
    @FacePreference(HazeColor.key) private var colorRaw = HazeColor.teal.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Detached windows must follow their own turn instead of the main chat.
    var sessionId: String? = nil

    var body: some View {
        FacePreferences(keys: [HazeColor.key]) { preferenceContent }
    }

    @ViewBuilder private var preferenceContent: some View {
        if !reduceTransparency {
            HazeLayer(
                color: HazeColor(stored: colorRaw),
                mood: mood,
                dark: colorScheme == .dark,
                still: reduceMotion
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .ignoresSafeArea()
        }
    }

    /// Read turn-phase sets instead of token events so haze invalidation stays bounded per turn.
    private var mood: HazeMood {
        guard let appModel else { return .idle }
        let id = sessionId ?? appModel.activeChatSessionId
        return appModel.turnPart("hazeMood", for: id) { turn -> HazeMood in
            guard let turn, turn.isWorking else { return .idle }
            return turn.isReplying ? .replying : .busy
        }
    }
}

private struct HazeLayer: NSViewRepresentable {
    var color: HazeColor
    var mood: HazeMood
    var dark: Bool
    var still: Bool

    func makeNSView(context: Context) -> HazeView { HazeView() }

    func updateNSView(_ view: HazeView, context: Context) {
        view.apply(color: color, mood: mood, dark: dark, still: still)
    }

    static func dismantleNSView(_ view: HazeView, coordinator: ()) { view.teardown() }
}
