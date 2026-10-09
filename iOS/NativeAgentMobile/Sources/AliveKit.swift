// AliveKit.swift
// "Alive glass" on the phone: the Mac's room ported (WindowHaze.swift,
// AlivePageKit.swift). One dark room, one slow single-hue haze drifting behind
// every tab, content as fills, glass only on the floating controls.
//
// COST. The drift is Core Animation, not SwiftUI: three radial-gradient layers
// carry additive keyframe loops the render server runs on its own. The main
// thread builds them once and then does nothing per frame. It acts only when
// the state changes (a turn starts, the scene backgrounds), ramping the
// container's speed and opacity for a second and a half.
//
// TEXT WINS. The brightest the haze can reach is all three discs overlapping
// at their centres at the busy opacity; the disc core is derived from that so
// the overlap never exceeds `peakAlpha`. At 0.44 the lightest preset shade
// over the dark room keeps body text ≈ 8:1 and the secondary token ≈ 5:1.

import SwiftUI
import UIKit

// MARK: - The colour setting

/// One hue, three shades. Same presets, hexes and storage key as the Mac, so
/// the name the agent picks by chat means the same colour here.
enum HazeColor: String, CaseIterable, Identifiable {
    case teal, blue, violet, rose, amber, forest, graphite

    static let key = "nativeagent.hazeColor"
    static let defaultValue: HazeColor = .teal

    init(stored raw: String) { self = HazeColor(rawValue: raw) ?? .teal }

    var id: String { rawValue }

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

    var swatch: Color { Color(uiColor: HazeColor.uiColor(shades[0])) }

    static func uiColor(_ hex: UInt) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// A switch's "on" track takes the base shade in dark; anything carrying a
    /// white label on the colour (a primary button) takes the deep shade,
    /// where the label clears 5:1. In light the deep shade goes 30% darker, so
    /// tinted words clear 5:1 even where the haze is brightest behind them.
    func control(dark: Bool, labelled: Bool) -> Color {
        guard !dark else { return Color(uiColor: HazeColor.uiColor(labelled ? shades[1] : shades[0])) }
        let deep = HazeColor.uiColor(shades[1])
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        deep.getRed(&r, green: &g, blue: &b, alpha: &a)
        return Color(uiColor: UIColor(red: r * 0.7, green: g * 0.7, blue: b * 0.7, alpha: 1))
    }
}

// MARK: - Tokens

enum AliveMetrics {
    static let cardRadius: CGFloat = 22
    static let rowInsetH: CGFloat = 18
    static let rowInsetV: CGFloat = 14
    /// Cards sit this far from the screen edge; headers, eyebrows and
    /// footnotes sit 4pt further in.
    static let pageInset: CGFloat = 16
    /// A tab root's door sits this far under the status bar, on every tab.
    static let rootTop: CGFloat = 8
    /// The title row holds a 44pt trailing control without growing.
    static let titleRow: CGFloat = 44
    static let lineRow: CGFloat = 22
}

/// Every text colour here clears 4.5:1 on the card fill and on the room where
/// all three haze discs overlap (light, at its 0.7 weight: secondary ≈ 6.5:1).
/// Tertiary grey does not; nothing here uses it.
enum AlivePalette {
    /// Dark: the Mac's night room. Light: warm paper, not a grey list.
    static let room = adaptive(dark: 0x12161F, light: 0xF2EDE4)
    // User 09-27: all native — the system label colours.
    static let text = Color(uiColor: .label)
    static let secondary = Color(uiColor: .secondaryLabel)
    /// User's own lines in chat: the label colour, lighter. `secondary` (a grey
    /// at 60%) measured 3.1:1 on the light haze; this is about 6:1 in both
    /// appearances and still reads quieter than her words.
    static let ownLine = text.opacity(0.64)
    /// The card fill: 6% white in dark; in light a translucent warm cream, so
    /// the haze reads through instead of a stark white slab.
    static let fill = tint(dark: UIColor.white.withAlphaComponent(0.06),
                           light: UIColor(red: 1, green: 0.985, blue: 0.955, alpha: 0.36))
    /// Inner top light on a card.
    static let highlight = tint(dark: UIColor.white.withAlphaComponent(0.14), light: UIColor.white.withAlphaComponent(0.85))
    /// The card's rim: a warm umber hairline in light.
    static let rim = tint(dark: UIColor.white.withAlphaComponent(0.05),
                          light: UIColor(red: 0.36, green: 0.26, blue: 0.16, alpha: 0.12))
    static let divider = Color(uiColor: .separator)

    private static func adaptive(dark: UInt, light: UInt) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? HazeColor.uiColor(dark) : HazeColor.uiColor(light) })
    }

    private static func tint(dark: UIColor, light: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

// MARK: - The room

enum HazeMood: Equatable {
    case idle, busy, replying

    /// Container opacity in dark; light takes 0.7 of it, enough to read as light.
    var opacity: Float {
        switch self {
        case .idle: return 0.52
        case .busy: return 0.62
        case .replying: return 0.56
        }
    }

    /// Multiplier on the idle loops (40 / 48 / 56 s).
    var speed: Float {
        switch self {
        case .idle: return 1
        case .busy: return 3.3
        case .replying: return 2
        }
    }
}

/// The room colour and the haze over it, edge to edge. Put it behind a screen
/// whose own backgrounds are clear.
struct AliveRoom: View {
    var mood: HazeMood = .idle
    @AppStorage(HazeColor.key) private var colorRaw = HazeColor.defaultValue.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            AlivePalette.room
            if !reduceTransparency {
                HazeBackdrop(color: HazeColor(stored: colorRaw), mood: mood,
                             dark: colorScheme == .dark, still: reduceMotion)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Reads the chat's turn state for the room's mood. Every input changes a few
/// times per turn; the representable ignores anything that is not a change.
struct AliveChatRoom: View {
    @ObservedObject var store: ChatStore

    var body: some View {
        AliveRoom(mood: mood)
    }

    private var mood: HazeMood {
        guard store.isLoading else { return .idle }
        guard let last = store.messages.last, last.role == .assistant, last.isStreaming, !last.text.isEmpty
        else { return .busy }
        return .replying
    }
}

struct HazeBackdrop: UIViewRepresentable {
    var color: HazeColor
    var mood: HazeMood
    var dark: Bool
    var still: Bool

    func makeUIView(context: Context) -> HazeUIView { HazeUIView() }

    func updateUIView(_ view: HazeUIView, context: Context) {
        view.apply(color: color, mood: mood, dark: dark, still: still)
    }

    static func dismantleUIView(_ view: HazeUIView, coordinator: ()) { view.teardown() }
}

/// Three radial-gradient discs in one container layer. The container's
/// `speed` is the tempo and the pause; the layer around it carries the weight,
/// so a pause never holds a fade.
final class HazeUIView: UIView {
    private static let peakAlpha: Double = 0.44
    /// 1 − (1 − busy·core)³ ≤ peakAlpha.
    private static let core: CGFloat = CGFloat(
        (1 - pow(1 - peakAlpha, 1.0 / 3.0)) / Double(HazeMood.busy.opacity))
    private static let ramp: TimeInterval = 1.5
    /// Light shows the haze at 0.7 of dark's weight: visible as light, text
    /// still ≥ 6:1 where all three discs overlap.
    private static let lightWeight: Float = 0.7
    /// A phone in portrait: tall soft discs, wider than the screen.
    private static let size = CGSize(width: 520, height: 600)
    private static let loops: [CFTimeInterval] = [40, 48, 56]
    /// Where each disc rests, as a fraction of the screen (y down).
    private static let anchors: [CGPoint] = [
        CGPoint(x: 0.10, y: 0.20), CGPoint(x: 0.92, y: 0.52), CGPoint(x: 0.30, y: 0.90),
    ]
    /// Each disc's loop, in points from its anchor.
    private static let paths: [[CGPoint]] = [
        [.zero, CGPoint(x: 110, y: 60), CGPoint(x: 60, y: 170), CGPoint(x: -70, y: 90), .zero],
        [.zero, CGPoint(x: -110, y: -90), CGPoint(x: -40, y: -190), CGPoint(x: 60, y: -70), .zero],
        [.zero, CGPoint(x: 90, y: -130), CGPoint(x: -60, y: -160), CGPoint(x: -90, y: -20), .zero],
    ]

    private let weight = CALayer()
    private let drift = CALayer()
    private var discs: [CAGradientLayer] = []
    private var color: HazeColor?
    private var mood: HazeMood = .idle
    private var dark = true
    private var still = false
    private var foreground = true
    private var observers: [NSObjectProtocol] = []
    private var rampLink: CADisplayLink?
    private var rampStart: (time: CFTimeInterval, from: Float, to: Float)?

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.masksToBounds = true
        weight.opacity = 0
        weight.actions = ["opacity": NSNull(), "bounds": NSNull(), "position": NSNull()]
        drift.actions = ["bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(weight)
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
            move.values = Self.paths[index].map { NSValue(cgPoint: $0) }
            move.isAdditive = true
            move.calculationMode = .cubic
            move.duration = loop
            move.repeatCount = .infinity
            move.isRemovedOnCompletion = false
            move.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 30, preferred: 20)
            move.timeOffset = loop * Double(index) / 3
            disc.add(move, forKey: "drift")
        }
        setSpeed(0)
        let center = NotificationCenter.default
        for (name, isForeground) in [(UIApplication.didEnterBackgroundNotification, false),
                                     (UIApplication.willEnterForegroundNotification, true)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.foreground = isForeground
                    self?.retarget()
                }
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        weight.frame = bounds
        drift.frame = bounds
        for (disc, anchor) in zip(discs, Self.anchors) {
            disc.position = CGPoint(x: bounds.width * anchor.x, y: bounds.height * anchor.y)
        }
        CATransaction.commit()
    }

    /// One haze clock for the whole app. Every screen draws its own haze (a
    /// tab host is opaque on iOS, so one room cannot sit behind them all);
    /// the one on screen writes the clock, and a screen arriving picks it up,
    /// so a tab switch or a push shows the same light in the same place.
    @MainActor private static var clock = (local: CFTimeInterval(0), wall: CACurrentMediaTime(), speed: Float(0))

    private static func clockNow(_ now: CFTimeInterval) -> CFTimeInterval {
        clock.local + (now - clock.wall) * Double(clock.speed)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            // Arrive in step and at full weight: no fade-in, no speed-up.
            rampLink?.invalidate()
            rampLink = nil
            let now = CACurrentMediaTime()
            drift.speed = (still || !foreground) ? 0 : mood.speed
            drift.timeOffset = Self.clockNow(now)
            drift.beginTime = now
            weight.removeAnimation(forKey: "weight")
            weight.opacity = mood.opacity * (dark ? 1 : Self.lightWeight)
            Self.clock = (drift.timeOffset, now, drift.speed)
        }
        retarget()
    }

    func teardown() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        rampLink?.invalidate()
        rampLink = nil
    }

    func apply(color: HazeColor, mood: HazeMood, dark: Bool, still: Bool) {
        if color != self.color {
            CATransaction.begin()
            CATransaction.setAnimationDuration(self.color == nil ? 0 : 1.2)
            CATransaction.setDisableActions(self.color == nil)
            for (disc, hex) in zip(discs, color.shades) {
                let base = HazeColor.uiColor(hex)
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

    /// Ease toward the current state: opacity by one CA fade, tempo by a short
    /// display-link ramp (a speed change is not animatable).
    private func retarget() {
        let targetOpacity = mood.opacity * (dark ? 1 : Self.lightWeight)
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

        let target: Float = (still || !foreground || window == nil) ? 0 : mood.speed
        rampLink?.invalidate()
        rampLink = nil
        guard drift.speed != target else { return }
        // Pausing (background, detached) is immediate; tempo changes ease.
        if target == 0 {
            setSpeed(target)
            return
        }
        rampStart = (CACurrentMediaTime(), drift.speed, target)
        let link = CADisplayLink(target: self, selector: #selector(stepRamp))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 15, preferred: 12)
        link.add(to: .main, forMode: .common)
        rampLink = link
    }

    @objc private func stepRamp() {
        guard let ramp = rampStart else { rampLink?.invalidate(); rampLink = nil; return }
        let t = min(1, (CACurrentMediaTime() - ramp.time) / Self.ramp)
        let eased = Float(t * t * (3 - 2 * t))
        setSpeed(ramp.from + (ramp.to - ramp.from) * eased)
        if t >= 1 {
            rampLink?.invalidate()
            rampLink = nil
            rampStart = nil
        }
    }

    /// Change tempo without a jump: rebase the container's clock so its local
    /// time at this instant is unchanged.
    private func setSpeed(_ speed: Float) {
        let now = CACurrentMediaTime()
        let local = drift.convertTime(now, from: nil)
        drift.speed = speed
        drift.timeOffset = local
        drift.beginTime = now
        if window != nil { Self.clock = (local, now, speed) }
    }
}

// MARK: - Page

/// True inside an AlivePage: the kit's sections, cards and rows are then
/// iOS's own List sections and cells (User 09-27: all native).
private struct AliveInListKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var aliveInList: Bool {
        get { self[AliveInListKey.self] }
        set { self[AliveInListKey.self] = newValue }
    }
}

/// A tab root hides the bar and wears the big serif door at one fixed height;
/// a pushed page or a sheet keeps its bar (Back, Done) and a smaller door.
enum AlivePageStyle { case root, pushed }

/// A page's door: a serif word with an optional trailing control on its row
/// (never a separate toolbar row), and ONE line under it. With `showsStatus`
/// (the chat header only), that line becomes the Mac connection status
/// whenever the Mac is not live; every other page's line describes the page.
/// The line is always held, so nothing below jumps when it arrives or swaps.
/// With `dot`, the agent's light sits before the name.
struct AlivePageHeader<Trailing: View>: View {
    let title: String
    var line: String?
    var dot: AliveStatusDot.State?
    var style: AlivePageStyle
    var showsStatus: Bool
    let trailing: Trailing
    @ScaledMetric(relativeTo: .largeTitle) private var rootSize: CGFloat = 34
    @ScaledMetric(relativeTo: .title) private var pushedSize: CGFloat = 28

    init(title: String, line: String? = nil, dot: AliveStatusDot.State? = nil, style: AlivePageStyle = .root,
         showsStatus: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.line = line
        self.dot = dot
        self.style = style
        self.showsStatus = showsStatus
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 10) {
                if let dot { AliveStatusDot(state: dot) }
                Text(title)
                    .font(.system(size: style == .root ? rootSize : pushedSize, weight: .regular, design: .serif))
                    .foregroundStyle(AlivePalette.text)
                    .lineLimit(style == .root ? 1 : 3)
                    .minimumScaleFactor(style == .root ? 0.7 : 1)
                    .fixedSize(horizontal: false, vertical: style == .pushed)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                trailing
            }
            .frame(minHeight: AliveMetrics.titleRow)
            Group {
                if showsStatus {
                    AliveConnectionLine(line: line)
                } else {
                    AliveHeaderLine(line: line)
                }
            }
            .padding(.leading, dot == nil ? 0 : 22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension AlivePageHeader where Trailing == EmptyView {
    init(title: String, line: String? = nil, dot: AliveStatusDot.State? = nil, style: AlivePageStyle = .root,
         showsStatus: Bool = false) {
        self.init(title: title, line: line, dot: dot, style: style, showsStatus: showsStatus) { EmptyView() }
    }
}

private struct AliveHeaderLine: View {
    let line: String?

    var body: some View {
        let shown = line.flatMap { $0.isEmpty ? nil : $0 }
        Text(shown ?? " ")
            .font(.subheadline)
            .foregroundStyle(AlivePalette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: AliveMetrics.lineRow, alignment: .leading)
            .opacity(shown == nil ? 0 : 1)
            .accessibilityHidden(shown == nil)
    }
}

/// The header line, or the Mac status in the agent's words when the Mac is
/// not live. The status keeps its full 44pt target but lays out at the line's
/// height, so the page never moves when it swaps in.
private struct AliveConnectionLine: View {
    let line: String?
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @EnvironmentObject private var pairingStore: PairingStore

    var body: some View {
        if bridgeClient.bridgeStatus == .online && pairingStore.isPaired {
            AliveHeaderLine(line: line)
        } else {
            MacStatusChip(speaksAsAgent: true)
                .frame(minHeight: 44, alignment: .leading)
                .padding(.vertical, (AliveMetrics.lineRow - 44) / 2)
        }
    }
}

/// The trailing control in a title row (the chat's `…`, the Desk's `+`): a
/// 44pt glass circle, because it floats on the functional layer.
struct AliveTitleControlLabel: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(AlivePalette.text)
            .frame(width: 44, height: 44)
            .aliveGlass(in: Circle(), interactive: true)
            .contentShape(Circle())
    }
}

/// The one page scaffold: the haze room, the door, an optional freshness note
/// and accessory (a segmented switch), then the page's sections. The door's
/// line describes the page; the Mac's status is said only in the chat header
/// and in More › Connection.
struct AlivePage<Trailing: View, Content: View>: View {
    let title: String
    var line: String?
    var style: AlivePageStyle
    var freshnessGroup: String?
    var accessory: AnyView?
    let trailing: Trailing
    let content: Content

    init(title: String, line: String? = nil, style: AlivePageStyle = .pushed,
         freshnessGroup: String? = nil, accessory: AnyView? = nil, @ViewBuilder trailing: () -> Trailing,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.line = line
        self.style = style
        self.freshnessGroup = freshnessGroup
        self.accessory = accessory
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        // iOS's own grouped List: native cells, separators, press highlight
        // and chevrons; her room and haze stay behind it.
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    AlivePageHeader(title: title, line: line, style: style) { trailing }
                        .padding(.horizontal, 4)
                    if let freshnessGroup { AliveFreshnessNote(group: freshnessGroup) }
                    if let accessory { accessory }
                }
                .aliveListRow(top: style == .root ? AliveMetrics.rootTop : 4, bottom: 4)
            }
            content
                .listRowBackground(AlivePalette.fill)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .environment(\.aliveInList, true)
        .alivePageChrome(title: title, root: style == .root)
    }
}

extension AlivePage where Trailing == EmptyView {
    init(title: String, line: String? = nil, style: AlivePageStyle = .pushed,
         freshnessGroup: String? = nil, accessory: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, line: line, style: style, freshnessGroup: freshnessGroup,
                  accessory: accessory, trailing: { EmptyView() }, content: content)
    }
}

extension View {
    /// The page chrome around any scroll or list: the room, the bar (hidden at
    /// a tab root, kept with Back when pushed), the undrawn title that
    /// VoiceOver still reads, the fade under the status bar (and, pushed,
    /// under the floating Back button), and the fade under the floating tab bar.
    func alivePageChrome(title: String, root: Bool) -> some View {
        mobileReadingScreen()
            .navigationTitle(title)
            .aliveHiddenTitle()
            .toolbar(root ? .hidden : .automatic, for: .navigationBar)
            .aliveTopFade(holdsBar: !root)
            .aliveBottomFade()
    }

    /// Scrolled content softens out under whatever floats at the bottom (the
    /// glass tab bar, the composer, the search): the system's soft scroll
    /// edge on iOS 26, and over it the room itself (room colour AND haze, in
    /// step with the one behind) fading in from just above the bar, so
    /// nothing reads through the glass and the haze still shows there. The
    /// bottom safe area already keeps the last row clear of the bar.
    func aliveBottomFade() -> some View {
        modifier(AliveBottomFade(room: AliveRoom()))
    }

    /// The same fade over a room with its own mood (the chat's).
    func aliveBottomFade<Room: View>(room: Room) -> some View {
        modifier(AliveBottomFade(room: room))
    }

    /// Scrolled content fades out under the status bar. `holdsBar` (a pushed
    /// page): the room itself (colour AND haze, like the bottom fade) covers
    /// the status bar and the bar with the floating Back button, fading out
    /// just below it, so nothing reads through the button.
    @ViewBuilder func aliveTopFade(_ on: Bool = true, holdsBar: Bool = false) -> some View {
        if holdsBar {
            overlay {
                GeometryReader { g in
                    let bar = g.safeAreaInsets.top
                    AliveRoom().mask {
                        VStack(spacing: 0) {
                            LinearGradient(stops: [.init(color: .black, location: 0),
                                                   .init(color: .black, location: max(0, bar - 8) / (bar + 16)),
                                                   .init(color: .clear, location: 1)],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: bar + 16)
                            Spacer(minLength: 0)
                        }
                        .ignoresSafeArea(edges: .top)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        } else if on {
            overlay(alignment: .top) {
                GeometryReader { g in
                    // From the screen's top edge down to the end of the status bar.
                    let y = g.frame(in: .global).minY
                    LinearGradient(colors: [AlivePalette.room, AlivePalette.room.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: y > 0 ? y : g.safeAreaInsets.top)
                        .offset(y: -y)
                }
                .frame(height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        } else {
            self
        }
    }

    /// A list row that is only its content: no cell, no separator, the page's
    /// side inset.
    func aliveListRow(top: CGFloat = 0, bottom: CGFloat = 0) -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: top, leading: AliveMetrics.pageInset, bottom: bottom,
                                      trailing: AliveMetrics.pageInset))
    }
}

private struct AliveBottomFade<Room: View>: ViewModifier {
    let room: Room

    func body(content: Content) -> some View {
        content.scrollEdgeEffectStyle(.soft, for: .bottom)
        .overlay {
            GeometryReader { g in
                // From 24pt above whatever floats at the bottom to the edge.
                let fade = g.safeAreaInsets.bottom + 24
                room.mask {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        LinearGradient(stops: [.init(color: .clear, location: 0),
                                               .init(color: .black.opacity(0.85), location: 0.5),
                                               .init(color: .black, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: fade)
                    }
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

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

// MARK: - Cards

extension View {
    /// The one card surface: a fill, a top light and a rim. Content layer, so
    /// never glass; the haze behind is what makes it read as glass.
    func aliveCard(radius: CGFloat = AliveMetrics.cardRadius) -> some View {
        modifier(AliveCardSurface(radius: radius))
    }
}

private struct AliveCardSurface: ViewModifier {
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @Environment(\.aliveInList) private var inList

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if inList { content } else { card(content, shape) }
    }

    private func card(_ content: Content, _ shape: RoundedRectangle) -> some View {
        content
            .background(reduceTransparency
                        ? AnyShapeStyle(NativeAgentMobileTheme.Colors.contentSurface)
                        : AnyShapeStyle(AlivePalette.fill), in: shape)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(stops: [.init(color: AlivePalette.highlight, location: 0),
                                           .init(color: AlivePalette.rim, location: 0.25)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            }
    }
}

/// ONE card holding rows; put an `AliveDivider()` between them.
struct AliveCard<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.aliveInList) private var inList

    var body: some View {
        if inList {
            Section { content }
        } else {
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .aliveCard()
        }
    }
}

extension View {
    /// A row inside an AliveCard: the card's inset, no chrome of its own.
    func aliveRow() -> some View { modifier(AliveRowInset()) }
}

private struct AliveRowInset: ViewModifier {
    @Environment(\.aliveInList) private var inList

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, inList ? 0 : AliveMetrics.rowInsetH)
            .padding(.vertical, inList ? 2 : AliveMetrics.rowInsetV)
    }
}

/// Between rows of a card; a List draws its own separators.
struct AliveDivider: View {
    @Environment(\.aliveInList) private var inList

    var body: some View {
        if !inList {
            Rectangle().fill(AlivePalette.divider).frame(height: 1)
                .padding(.leading, AliveMetrics.rowInsetH)
                .accessibilityHidden(true)
        }
    }
}

/// The card for what waits on you: the kit's card, lit from the top with the
/// haze. Waiting on you is the haze colour's one job.
struct AliveWaitingCard<Content: View>: View {
    @ViewBuilder var content: Content
    @AppStorage(HazeColor.key) private var colorRaw = HazeColor.defaultValue.rawValue
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let haze = HazeColor(stored: colorRaw).control(dark: colorScheme == .dark, labelled: false)
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .top) {
                LinearGradient(colors: [haze.opacity(colorScheme == .dark ? 0.22 : 0.14), haze.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 96)
            }
            .clipShape(RoundedRectangle(cornerRadius: AliveMetrics.cardRadius, style: .continuous))
            .aliveCard()
    }
}

// MARK: - Sections and rows

/// Section label: small caps in full secondary (the Mac's AliveEyebrow).
struct AliveEyebrow: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(1.0)
            .foregroundStyle(AlivePalette.secondary)
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// An eyebrow, what it labels (one card of rows by default), and an optional
/// quiet line under it.
struct AliveSection<Trailing: View, Content: View>: View {
    enum Surface { case card, waiting, none }
    let title: String?
    var footer: String?
    var surface: Surface
    let trailing: Trailing
    let content: Content

    init(_ title: String?, footer: String? = nil, surface: Surface = .card,
         @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.surface = surface
        self.trailing = trailing()
        self.content = content()
    }

    @Environment(\.aliveInList) private var inList
    @AppStorage(HazeColor.key) private var colorRaw = HazeColor.defaultValue.rawValue
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if inList { listSection } else { stack }
    }

    private var listSection: some View {
        let haze = HazeColor(stored: colorRaw).control(dark: colorScheme == .dark, labelled: false)
        return Section {
            if surface == .waiting {
                content.listRowBackground(
                    LinearGradient(colors: [haze.opacity(colorScheme == .dark ? 0.22 : 0.14), AlivePalette.fill],
                                   startPoint: .top, endPoint: .bottom))
            } else {
                content
            }
        } header: {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                    Spacer(minLength: 8)
                    trailing.textCase(nil)
                }
            }
        } footer: {
            if let footer, !footer.isEmpty { Text(footer) }
        }
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    AliveEyebrow(title)
                    Spacer(minLength: 8)
                    trailing.padding(.trailing, 4)
                }
            }
            switch surface {
            case .card: AliveCard { content }
            case .waiting: AliveWaitingCard { content }
            case .none: content
            }
            if let footer, !footer.isEmpty { AliveFootnote(footer) }
        }
    }
}

extension AliveSection where Trailing == EmptyView {
    init(_ title: String?, footer: String? = nil, surface: Surface = .card, @ViewBuilder content: () -> Content) {
        self.init(title, footer: footer, surface: surface, trailing: { EmptyView() }, content: content)
    }
}

/// A quiet line under a card.
struct AliveFootnote: View {
    let text: String
    var systemImage: String?
    init(_ text: String, systemImage: String? = nil) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .foregroundStyle(AlivePalette.secondary)
        .padding(.horizontal, 4)
    }
}

/// The one row: a name, its detail in secondary text, and an optional
/// trailing control (an `AliveChevron` makes it a link row).
struct AliveRow<Trailing: View>: View {
    let title: String
    var detail: String?
    var detailLines: Int?
    let trailing: Trailing

    init(_ title: String, detail: String? = nil, detailLines: Int? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.detailLines = detailLines
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(AlivePalette.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(AlivePalette.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(detailLines)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .aliveRow()
        .contentShape(Rectangle())
    }
}

extension AliveRow where Trailing == EmptyView {
    init(_ title: String, detail: String? = nil, detailLines: Int? = nil) {
        self.init(title, detail: detail, detailLines: detailLines, trailing: { EmptyView() })
    }
}

/// A label on the left, its value in secondary text on the right.
struct AliveValueRow: View {
    let label: String
    let value: String
    var valueColor: Color = AlivePalette.secondary
    var emphasized = false

    var body: some View {
        MobileAdaptiveRow(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(AlivePalette.text)
            Spacer(minLength: 8)
            Text(value)
                .fontWeight(emphasized ? .medium : .regular)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .aliveRow()
        .accessibilityElement(children: .combine)
    }
}

/// A quiet sentence inside a card.
struct AliveNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(AlivePalette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .aliveRow()
    }
}

/// A row that does something: its words in the haze, the one tinted control.
struct AliveTapRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(.tint)
                .aliveRow()
                .contentShape(Rectangle())
        }
        .aliveRowButtonStyle()
        .hazeTinted()
    }
}

struct AliveChevron: View {
    @Environment(\.aliveInList) private var inList

    var body: some View {
        if !inList { chevron }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(AlivePalette.secondary)
            .accessibilityHidden(true)
    }
}

/// Rows carry no chrome; a press shows a soft inset wash.
extension View {
    /// A row's press: in a List the cell's own native highlight; elsewhere a
    /// soft inset wash.
    func aliveRowButtonStyle() -> some View { modifier(AliveRowPress()) }
}

private struct AliveRowPress: ViewModifier {
    @Environment(\.aliveInList) private var inList

    func body(content: Content) -> some View {
        if inList { content } else { content.buttonStyle(AliveRowButtonStyle()) }
    }
}

struct AliveRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if configuration.isPressed {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AlivePalette.divider)
                        .padding(4)
                }
            }
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
        // iOS's own segmented control (User 09-27: all native).
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

/// ONE wording for where the Mac stands. The chat header, More › Connection,
/// Settings › Connection and Status all say it through here, so no two
/// places diagnose the same state differently. Other pages never say it.
enum AliveConnection {
    static let unpaired = "Not paired with your Mac yet"
    static let unreachable = "I can\u{2019}t reach your Mac right now"
    static let noICloud = "No iCloud on this iPhone"
    /// The one reason on every control the phone cannot use yet.
    static let pairToChange = "Pair with your Mac to change this"

    static func line(for status: BridgeStatus, paired: Bool) -> String {
        if status == .iCloudAccountAttention { return status.displayName }
        guard paired else { return unpaired }
        switch status {
        case .online: return "Here"
        case .offline: return noICloud
        case .iCloudAccountAttention: return status.displayName
        case .macUnreachable, .stale, .awaitingMacActivity: return unreachable
        case .deviceOffline: return "You\u{2019}re offline. I\u{2019}ll send when you\u{2019}re back"
        case .connecting: return "Finding your Mac\u{2026}"
        }
    }
}

/// The one reason on a page whose controls the phone cannot use yet, with
/// the one way on. Every such control wears `aliveUnavailable`, so they all
/// dim the same way and none shows a value the Mac has not sent.
struct AliveUnpairedReason: View {
    var showsAction = true
    @State private var showsPairing = false

    var body: some View {
        if showsAction {
            AliveStatusNote(systemImage: "lock", text: AliveConnection.pairToChange + ".",
                            actionTitle: "Pair with Mac", actionHint: "Connects this iPhone to your Mac") {
                showsPairing = true
            }
            .sheet(isPresented: $showsPairing) {
                PairingView(onSkip: { showsPairing = false }, onPaired: { showsPairing = false })
            }
        } else {
            AliveFootnote(AliveConnection.pairToChange + ".", systemImage: "lock")
        }
    }
}

extension View {
    /// A control the phone cannot use yet: off and dimmed, the same everywhere.
    func aliveUnavailable(_ off: Bool) -> some View {
        disabled(off).opacity(off ? 0.5 : 1)
    }
}

/// The snapshot's age for one Mac group, said once under the header; nothing
/// while fresh. An unpaired phone gets only "Pair with Mac" (the page's own
/// dimmed state says the rest); a paired one hears this page's age when it
/// is stale or never arrived.
struct AliveFreshnessNote: View {
    @ObservedObject private var sync = iCloudSyncEngine.shared
    @EnvironmentObject private var pairingStore: PairingStore
    @State private var showsPairing = false
    let group: String

    var body: some View {
        let reason = MacSnapshotGroupStaleness.reason(in: sync.staleSnapshotGroups, group: group)
        if !pairingStore.usesICloudTransport {
            AliveNoteAction(title: "Pair with Mac", hint: "Connects this iPhone to your Mac") { showsPairing = true }
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sheet(isPresented: $showsPairing) {
                    PairingView(onSkip: { showsPairing = false }, onPaired: { showsPairing = false })
                }
        } else {
            MacSnapshotFreshnessBadge(
                // THIS group's last delivery, not the last cache read: a Desk
                // delivery is not evidence that Approvals arrived.
                lastSyncedAt: sync.transportDeliveryAt(screenGroup: group),
                staleGroupReason: reason)
        }
    }
}

// MARK: - Words

/// Plain words the way the Mac pages say them.
enum AliveWords {
    private static let ones = ["zero", "one", "two", "three", "four", "five", "six",
                               "seven", "eight", "nine", "ten"]

    /// "Three", not "3", up to ten; digits after.
    static func spelled(_ n: Int, capitalized: Bool = true) -> String {
        guard ones.indices.contains(n) else { return "\(n)" }
        let word = ones[n]
        return capitalized ? word.prefix(1).uppercased() + word.dropFirst() : word
    }

    /// The one pluralizer for every count on screen: "1 tool", "2 tools",
    /// "3 replies", "2 thinking". `spelled` says "Two tools" up to ten.
    static func count(_ n: Int, _ noun: String, plural: String? = nil, spelled: Bool = false) -> String {
        let number = spelled ? self.spelled(n, capitalized: false) : n.formatted()
        return "\(number) \(n == 1 ? noun : plural ?? pluralized(noun))"
    }

    private static func pluralized(_ noun: String) -> String {
        if noun.hasSuffix("ing") || noun.hasSuffix("s") { return noun }
        if noun.hasSuffix("y"), let before = noun.dropLast().last, !"aeiou".contains(before) {
            return noun.dropLast() + "ies"
        }
        return noun + "s"
    }

    /// Snake-, kebab- and dot-case ids read as words: "calendar_read" → "Calendar read".
    static func humanized(_ raw: String) -> String {
        guard raw.contains(where: { $0 == "_" || $0 == "." || $0 == "-" }) || raw == raw.lowercased() else {
            return raw
        }
        let spaced = raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let first = spaced.first else { return raw }
        return first.uppercased() + spaced.dropFirst()
    }

    static func date(_ iso: String) -> Date? {
        if let date = try? Date(iso, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return try? Date(iso, strategy: .iso8601)
    }

    /// An ISO stamp said like a person would: "20 min. ago".
    static func relative(_ iso: String?) -> String? {
        guard let iso, let date = date(iso) else { return nil }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    static func readable(_ iso: String) -> String {
        date(iso)?.formatted(date: .abbreviated, time: .shortened) ?? iso
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
