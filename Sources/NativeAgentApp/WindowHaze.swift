// WindowHaze.swift
// "Alive glass", first half — User approved the mockup 2026-09-23. Behind every
// column's content sits ONE single-hue haze that drifts like soft light in
// fog: three very large, very soft discs in three shades of one hue, at low
// opacity, on long slow loops. Drawn once for the whole window, above the
// sheet and its coat, below the columns (ShellFrame), like the lamp.
//
// COST. The drift is Core Animation, not SwiftUI: three radial-gradient
// layers carry additive keyframe animations that the render server runs on
// its own. The main thread builds the layers once and then does nothing per
// frame — no body, no layout, no display list. It only acts when the state
// changes (a turn starts, text starts streaming, the window hides), and then
// it ramps the container's `speed` and `opacity` for a second and a half.
// A radial gradient IS the blurred disc, so there is no blur pass at all.
//
// TEXT WINS (the agent, 2026-09-23). The brightest point the haze can reach is
// all three discs overlapping at their centres at the busy opacity; the disc
// core is derived from that so the overlap never exceeds `peakAlpha`. At 0.35
// (0.5 since User's first look: 0.35 read as no haze at all; body text keeps >6:1)
// the lightest preset shade (amber #dc9a3d) over the dark room (#12161F)
// measures L ≈ 0.064: body text (#F6F3EE) keeps ≈ 8:1 and even the secondary
// token (#C1C6CC) keeps ≈ 5:1.

import AppKit
import SwiftUI

// MARK: - The colour setting

/// One hue, three shades. The whole palette — the agent may pick any of these
/// by chat and nothing else (`settings.haze_color`).
enum HazeColor: String, CaseIterable, Identifiable {
    case teal, blue, violet, rose, amber, forest, graphite

    static let key = "nativeagent.hazeColor"
    static let storageKey = key
    static let defaultValue: HazeColor = .teal

    init(stored raw: String) { self = HazeColor(rawValue: raw) ?? .teal }

    var id: String { rawValue }

    /// The accessibility name, and the word the Settings swatch speaks.
    var name: String {
        switch self {
        case .forest: return "Forest green"
        default: return rawValue.capitalized
        }
    }

    var shades: [UInt] {
        switch self {
        case .teal:     return [0x17A597, 0x0F7C78, 0x1CB8A6]
        case .blue:     return [0x2F6FD6, 0x1F4FA8, 0x3C86E8]
        case .violet:   return [0x7A52D6, 0x5A3AA8, 0x8D66EA]
        case .rose:     return [0xC9486E, 0x9C3456, 0xDC5F84]
        case .amber:    return [0xC9852C, 0x9C6220, 0xDC9A3D]
        case .forest:   return [0x3F9A52, 0x2C753C, 0x4FB064]
        case .graphite: return [0x6B7280, 0x4B5260, 0x7D8595]
        }
    }

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
    var swatch: Color { Color(nsColor: HazeColor.nsColor(shades[0])) }

    static func nsColor(_ hex: UInt) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// A switch's "on" track: the base shade in dark (≥3.4:1 on the room for
    /// every preset), the deep shade in light (the base teal and amber are
    /// 2.8:1 on the light room; every deep shade clears 4.5). Anything that
    /// carries a white label on the colour — a selected segment, a primary
    /// button — always takes the deep shade: the label is ≥5:1 there, and
    /// only 3.1:1 on the base teal and amber.
    func control(dark: Bool, labelled: Bool) -> NSColor {
        HazeColor.nsColor(dark && !labelled ? shades[0] : shades[1])
    }
}

// MARK: - Controls wear the haze

extension View {
    /// Tint ONE control's "on" state with the chosen haze (User, 2026-09-23:
    /// system blue clashed with the single-hue glass). Per control, never a
    /// page: a page-level `.tint` is an accent on everything.
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

// MARK: - The state

enum HazeMood: Equatable {
    case idle, busy, replying

    /// Container opacity, dark appearance. Light takes half.
    var opacity: Float {
        switch self {
        case .idle: return 0.52
        case .busy: return 0.62
        case .replying: return 0.56
        }
    }

    /// Multiplier on the idle loops (40 / 48 / 56 s): busy → 12–17 s,
    /// replying → 20–28 s.
    var speed: Float {
        switch self {
        case .idle: return 1
        case .busy: return 3.3
        case .replying: return 2
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
        guard let appModel, appModel.isBusy || appModel.isChatStreaming else { return .idle }
        return appModel.replyingSessions.contains(appModel.activeChatSessionId) ? .replying : .busy
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

/// Three radial-gradient discs in one container layer. The container's
/// `speed` is the tempo and the pause; the layer around it carries the
/// state's weight, so a pause never holds a fade.
final class HazeView: NSView {
    /// The brightest the haze may ever be: all three discs overlapping at
    /// their centres, at the busy opacity. See the header for the contrast.
    private static let peakAlpha: Double = 0.44
    /// The disc's own core alpha, derived from the cap:
    /// 1 − (1 − busy·core)³ ≤ peakAlpha.
    private static let core: CGFloat = CGFloat(
        (1 - pow(1 - peakAlpha, 1.0 / 3.0)) / Double(HazeMood.busy.opacity))
    private static let ramp: TimeInterval = 1.5
    private static let size = CGSize(width: 640, height: 580)
    /// Idle loop lengths, one per disc.
    private static let loops: [CFTimeInterval] = [40, 48, 56]
    /// Where each disc rests, as a fraction of the window.
    private static let anchors: [CGPoint] = [
        CGPoint(x: 0.18, y: 0.70), CGPoint(x: 0.74, y: 0.42), CGPoint(x: 0.46, y: 0.16),
    ]
    /// Each disc's loop, in points from its anchor.
    private static let paths: [[CGPoint]] = [
        [.zero, CGPoint(x: 160, y: -60), CGPoint(x: 90, y: -170), CGPoint(x: -120, y: -90), .zero],
        [.zero, CGPoint(x: -150, y: 90), CGPoint(x: -60, y: 180), CGPoint(x: 110, y: 70), .zero],
        [.zero, CGPoint(x: 120, y: 130), CGPoint(x: -100, y: 160), CGPoint(x: -140, y: 20), .zero],
    ]

    /// The weight (opacity) lives on its own layer, outside the tempo: a
    /// paused `drift` also froze any fade attached to it, so a haze built
    /// while the window was in the background (a Simple | Advanced swap from
    /// the agent, a launch behind other windows) held at opacity 0 until the
    /// app was next activated. Simple view read as flat #20232A.
    private let weight = CALayer()
    private let drift = CALayer()
    private var discs: [CAGradientLayer] = []
    private var color: HazeColor?
    private var mood: HazeMood = .idle
    private var dark = true
    private var still = false
    private var observers: [NSObjectProtocol] = []
    private var rampTimer: Timer?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        weight.opacity = 0
        weight.actions = ["opacity": NSNull(), "bounds": NSNull(), "position": NSNull()]
        drift.actions = ["bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(weight)
        weight.addSublayer(drift)
        for (index, loop) in Self.loops.enumerated() {
            let disc = CAGradientLayer()
            disc.type = .radial
            disc.startPoint = CGPoint(x: 0.5, y: 0.5)
            disc.endPoint = CGPoint(x: 1, y: 1)
            disc.locations = [0, 0.35, 0.7, 1]
            disc.bounds = CGRect(origin: .zero, size: Self.size)
            disc.actions = ["position": NSNull(), "bounds": NSNull()]
            drift.addSublayer(disc)
            discs.append(disc)

            let move = CAKeyframeAnimation(keyPath: "position")
            move.values = Self.paths[index].map { NSValue(point: $0) }
            move.isAdditive = true
            move.calculationMode = .cubic
            move.duration = loop
            move.repeatCount = .infinity
            move.isRemovedOnCompletion = false
            // Slow light needs few frames; the render server can idle between.
            move.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 30, preferred: 20)
            // Start each disc somewhere along its loop, not all at the origin.
            move.timeOffset = loop * Double(index) / 3
            disc.add(move, forKey: "drift")
        }
        setSpeed(0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// SwiftUI sizes a representable by frame; that alone never runs layout().
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        weight.frame = bounds
        drift.frame = bounds
        for (disc, anchor) in zip(discs, Self.anchors) {
            disc.position = CGPoint(x: bounds.width * anchor.x, y: bounds.height * anchor.y)
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        let center = NotificationCenter.default
        let names: [(Notification.Name, AnyObject?)] = [
            (NSWindow.didChangeOcclusionStateNotification, window),
            (NSApplication.didBecomeActiveNotification, NSApp),
            (NSApplication.didResignActiveNotification, NSApp),
        ]
        for (name, object) in names {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.retarget() }
            })
        }
        retarget()
    }

    func teardown() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        rampTimer?.invalidate()
        rampTimer = nil
    }

    func apply(color: HazeColor, mood: HazeMood, dark: Bool, still: Bool) {
        if color != self.color || dark != self.dark {
            // A colour change crossfades; the first paint does not.
            CATransaction.begin()
            CATransaction.setAnimationDuration(self.color == nil ? 0 : 1.2)
            CATransaction.setDisableActions(self.color == nil)
            for (disc, hex) in zip(discs, color.shades) {
                let base = HazeColor.nsColor(hex)
                let k = Self.core
                disc.colors = [k, k * 0.9, k * 0.45, 0].map { base.withAlphaComponent($0).cgColor }
            }
            CATransaction.commit()
        }
        let changed = mood != self.mood || dark != self.dark || still != self.still || self.color == nil
        self.color = color
        self.mood = mood
        self.dark = dark
        self.still = still
        if changed { retarget() }
    }

    // MARK: Tempo and weight

    private var visible: Bool {
        guard let window else { return false }
        return NSApp.isActive && window.occlusionState.contains(.visible)
    }

    /// Ease the container toward the current state: opacity by one CA fade,
    /// tempo by a short main-thread ramp (a speed change is not animatable).
    private func retarget() {
        let targetOpacity = mood.opacity * (dark ? 1 : 0.5)
        let from = weight.presentation()?.opacity ?? weight.opacity
        if from != targetOpacity {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = targetOpacity
            fade.duration = Self.ramp
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            weight.opacity = targetOpacity
            weight.add(fade, forKey: "weight")
        }

        let target: Float = (still || !visible) ? 0 : mood.speed
        let start = drift.speed
        rampTimer?.invalidate()
        rampTimer = nil
        guard start != target else { return }
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] timer in
            let done = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return true }
                let t = min(1, (CACurrentMediaTime() - began) / Self.ramp)
                let eased = Float(t * t * (3 - 2 * t))
                self.setSpeed(start + (target - start) * eased)
                if t >= 1 { self.rampTimer = nil }
                return t >= 1
            }
            if done { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        rampTimer = timer
    }

    /// Change tempo without a jump: rebase the container's clock so its local
    /// time at this instant is unchanged (QA1673's pause, generalised).
    private func setSpeed(_ speed: Float) {
        let now = CACurrentMediaTime()
        let local = drift.convertTime(now, from: nil)
        drift.speed = speed
        drift.timeOffset = local
        drift.beginTime = now
    }
}
