import NativeAgentShared
import AppToolRuntime

// Blueprint: | `WindowHaze.swift` | Mac window haze palette, controls and shared `HazeView` presentation |
// One single-hue haze drifts above the shared sheet and below every column.
// Core Animation drives three radial-gradient discs without per-frame main-thread work.
// Disc cores cap their combined overlap at 0.44 alpha to preserve text contrast.

import AppKit
import SwiftUI

// MARK: - The colour setting

extension HazeColor {
    /// The haze itself, for glows on glass.
    var base: Color { swatch }

    /// Its light shade, for light that travels on glass edges.
    var edgeLight: Color {
        switch self {
        case .teal: Color(hex: 0xA0F0E4)
        case .blue: Color(hex: 0xAAC8FF)
        case .violet: Color(hex: 0xCDB9FF)
        case .rose: Color(hex: 0xFFBED2)
        case .amber: Color(hex: 0xFFDCAA)
        case .forest: Color(hex: 0xBEF0C8)
        case .graphite: Color(hex: 0xDCE1EB)
        }
    }

    /// The swatch colour: the middle-bright shade.
    var swatch: Color { Color(hex: shades[0]) }

    /// Root control ink: retain the dark swatch, deepen it on the light room.
    func windowTint(dark: Bool) -> Color {
        guard !dark else { return base }
        let deep = NSColor(Color(hex: shades[1]))
        return Color(nsColor: NSColor(srgbRed: deep.redComponent * 0.7,
                                     green: deep.greenComponent * 0.7,
                                     blue: deep.blueComponent * 0.7, alpha: 1))
    }

    /// A switch's "on" track: the base shade in dark (≥3.4:1 on the room for
    /// every preset), the deep shade in light (the base teal and amber are
    /// 2.8:1 on the light room; every deep shade clears 4.5). Anything that
    /// carries a white label on the colour — a selected segment, a primary
    /// button — always takes the deep shade: the label is ≥5:1 there, and
    /// only 3.1:1 on the base teal and amber.
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
    @AppStorage(HazeColor.key) private var colorRaw = HazeColor.defaultValue.rawValue
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let color = HazeColor(stored: colorRaw).control(dark: colorScheme == .dark, labelled: kind != .toggle)
        content
            .tint(Color(nsColor: color))
            // `.tint` never reaches a segmented picker's selected segment;
            // its AppKit control takes the colour directly.
            .background { if kind == .segments { SegmentBezelTint(color: color) } }
    }
}

/// Finds the NSSegmentedControl this sits behind and sets its selected
/// segment's colour. Inert behind anything else.
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

/// The SwiftUI seam: reads the turn state and the setting, draws nothing under
/// Reduce Transparency, holds still under Reduce Motion.
struct WindowHaze: View {
    /// Optional so the headless snapshot renderers, which build a ShellFrame
    /// with no model, get a still idle haze instead of a trap.
    @Environment(AppModel.self) private var appModel: AppModel?
    @AppStorage(HazeColor.key) private var colorRaw = HazeColor.teal.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// The conversation whose turn moves the haze: a detached chat window's
    /// own. nil is the main window's active chat.
    var sessionId: String? = nil

    var body: some View {
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

    /// The composer's own "a turn is running" (the stop button's condition),
    /// split by whether reply text has started to arrive. Every input is a
    /// set that changes a few times per turn, never per token.
    private var mood: HazeMood {
        guard let appModel else { return .idle }
        let id = sessionId ?? appModel.activeChatSessionId
        guard appModel.engine.turns.isBusy(id) || appModel.engine.turns.isStreaming(id) else { return .idle }
        return appModel.engine.turns.replyingSessions.contains(id) ? .replying : .busy
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
