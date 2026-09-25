import SwiftUI

// "Alive glass" (User, 2026-09-23): while she is working on a turn and has not
// started her reply, light moves in the glass — a caustic shimmer in the
// composer and the rail, and a line of light travelling round the composer's
// edge. Agent, same day: it stops (0.4s fade) the moment reply text starts
// streaming, and stays off while it streams; the words are the signal then.
//
// Performance: everything here is a leaf. The signal is read in `ThinkingGlow`
// itself, never in ChatView or the composer, so a lifecycle tick invalidates
// this view and nothing else. The motion is a TimelineView driving a Canvas
// that sits in a background/overlay: an overlay is sized by its host and never
// proposes a size back, so a frame here re-draws one layer and re-lays-out
// nothing — not the composer, not the transcript. The fade animates one
// @State that only this leaf reads, so its transaction never reaches anything
// else.

extension AppModel {
    /// She is working on the open conversation's turn and no reply text has
    /// streamed yet. A retry resets the streamed length, so a retried turn
    /// reads as thinking again until its new text arrives.
    var isThinkingBeforeReply: Bool {
        guard isBusy || isChatStreaming else { return false }
        guard let lifecycle = chatTurnLifecycle(for: activeChatSessionId) else { return true }
        return !lifecycle.presentation.isTerminal && lifecycle.presentation.streamedTextLength == 0
    }
}

/// One thinking effect, masked to a rounded rectangle of `cornerRadius`.
/// Put `.shimmer` under content (a background, before `glassEffect`) and
/// `.rim` over it (an overlay).
struct ThinkingGlow: View {
    enum Kind { case shimmer, rim }
    let kind: Kind
    let cornerRadius: CGFloat
    /// Absent in snapshots and panels without the model: then it never shows.
    @Environment(AppModel.self) private var appModel: AppModel?

    var body: some View {
        ThinkingGlowLayer(
            kind: kind,
            cornerRadius: cornerRadius,
            thinking: appModel?.isThinkingBeforeReply ?? false
        )
    }
}

private struct ThinkingGlowLayer: View {
    let kind: ThinkingGlow.Kind
    let cornerRadius: CGFloat
    let thinking: Bool

    @AppStorage(HazeColor.storageKey) private var hazeRaw = HazeColor.defaultValue.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the fade; read only here, so its animation stays in this leaf.
    @State private var shown = false
    /// Stays true through the fade-out so the light keeps moving while it goes.
    @State private var running = false

    static let fade = 0.4
    static let rimPeriod = 2.6
    /// One slide of the shimmer; a full there-and-back is twice this.
    static let shimmerSlide = 3.0

    var body: some View {
        Group {
            if running { effect }
        }
        .opacity(shown ? 1 : 0)
        .onChange(of: thinking, initial: true) { _, now in
            if now { running = true }
            withAnimation(.easeInOut(duration: Self.fade)) {
                shown = now
            } completion: {
                if !shown { running = false }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var effect: some View {
        let haze = HazeColor(stored: hazeRaw)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceMotion {
            // No travel: a still rim, a step brighter than the moving arc's
            // average, says she is thinking. No shimmer.
            if kind == .rim {
                shape.strokeBorder(haze.edgeLight.opacity(0.42), lineWidth: 1.5)
            }
        } else {
            // The rim's canvas reaches past the host by `rimBleed` so its glow
            // is not clipped at the glass edge.
            let bleed = kind == .rim ? Self.rimBleed : 0
            TimelineView(.animation(paused: !running)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                Canvas(rendersAsynchronously: true) { context, size in
                    switch kind {
                    case .rim: drawRim(in: &context, size: size, t: t, light: haze.edgeLight)
                    case .shimmer: drawShimmer(in: &context, size: size, t: t, light: haze.edgeLight)
                    }
                }
            }
            .padding(-bleed)
        }
    }

    static let rimBleed: CGFloat = 12

    /// A 2pt stroke of the rounded rectangle, lit by one ~70° comet of a conic
    /// gradient that turns once every `rimPeriod`: full brightness at the
    /// head, fading back along the tail, over the same arc blurred 6pt at half
    /// opacity. It reads as the agent working, not as a reflection.
    private func drawRim(in context: inout GraphicsContext, size: CGSize, t: Double, light: Color) {
        let line: CGFloat = 2
        let inset = Self.rimBleed + line / 2
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        let path = RoundedRectangle(cornerRadius: max(0, cornerRadius - line / 2), style: .continuous)
            .path(in: rect)
        // Wider than the composer's 70°: on a 30pt avatar a short arc read as
            // a speck (User 09-23 wanted the outline itself to shine).
            let arc = 130.0 / 360.0, lead = 4.0 / 360.0
        let gradient = Gradient(stops: [
            .init(color: light.opacity(0), location: 0),
            .init(color: light.opacity(0), location: 0.5 - arc),
            .init(color: light.opacity(0.35), location: 0.5 - arc * 0.4),
            .init(color: light.opacity(1), location: 0.5),
            .init(color: light.opacity(0), location: 0.5 + lead),
            .init(color: light.opacity(0), location: 1),
        ])
        let turn = (t / Self.rimPeriod).truncatingRemainder(dividingBy: 1)
        let shading = GraphicsContext.Shading.conicGradient(
            gradient,
            center: CGPoint(x: size.width / 2, y: size.height / 2),
            angle: .degrees(turn * 360)
        )
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 6))
            glow.opacity = 0.5
            glow.stroke(path, with: shading, lineWidth: line * 2)
        }
        context.stroke(path, with: shading, lineWidth: line)
    }

    /// Two soft radial pools of the haze's light shade sliding past each other
    /// along the shape's long axis, trading brightness as they go.
    private func drawShimmer(in context: inout GraphicsContext, size: CGSize, t: Double, light: Color) {
        context.clip(to: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .path(in: CGRect(origin: .zero, size: size)))
        let theta = t * .pi / Self.shimmerSlide
        let s = sin(theta), c = cos(theta)
        let wide = size.width >= size.height
        let radius = max(min(size.width, size.height) * 1.3, 60)
        func pool(along: Double, across: Double, alpha: Double) {
            let center = wide
                ? CGPoint(x: size.width * along, y: size.height * across)
                : CGPoint(x: size.width * across, y: size.height * along)
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(colors: [light.opacity(alpha), light.opacity(0)]),
                    center: center, startRadius: 0, endRadius: radius
                )
            )
        }
        pool(along: 0.5 + 0.55 * s, across: 0.3, alpha: 0.30 * (0.55 + 0.45 * c))
        pool(along: 0.5 - 0.55 * s, across: 0.75, alpha: 0.30 * (0.55 - 0.45 * c))
    }
}

/// The composer's faint inner glow along its bottom edge, in the haze colour.
struct HazeBottomGlow: View {
    let cornerRadius: CGFloat
    @AppStorage(HazeColor.storageKey) private var hazeRaw = HazeColor.defaultValue.rawValue

    var body: some View {
        let haze = HazeColor(stored: hazeRaw)
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(LinearGradient(
                colors: [haze.base.opacity(0), haze.base.opacity(0.08)],
                startPoint: UnitPoint(x: 0.5, y: 0.45),
                endPoint: .bottom
            ))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The composer's travelling rim, sized to an avatar: a 70° comet of the
/// haze's light shade going round the avatar's edge once every `rimPeriod`,
/// with a soft glow. Mount it only while that avatar's contact, helper or crew
/// is working; idle is no view at all. Reduce Motion gets a still, soft rim.
///
/// Core Animation, not SwiftUI: one rotation the render server runs, so a
/// working avatar costs the main thread nothing per frame (a SwiftUI
/// repeatForever pinned Simple view's CPU; see SimpleBreathingOrb).
struct WorkingRim: View {
    /// The avatar's own corner radius: half its side for a circle.
    let cornerRadius: CGFloat
    @AppStorage(HazeColor.storageKey) private var hazeRaw = HazeColor.defaultValue.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let haze = HazeColor(stored: hazeRaw)
        Group {
            if reduceMotion {
                RoundedRectangle(cornerRadius: cornerRadius + 2, style: .continuous)
                    .strokeBorder(haze.edgeLight.opacity(0.42), lineWidth: 1.5)
                    .padding(-2)
            } else {
                WorkingRimLayer(haze: haze, cornerRadius: cornerRadius)
                    .padding(-WorkingRimLayer.bleed)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct WorkingRimLayer: NSViewRepresentable {
    /// Room past the avatar for the ring and its glow.
    static let bleed: CGFloat = 6
    var haze: HazeColor
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> RimView { RimView() }
    func updateNSView(_ view: RimView, context: Context) { view.apply(haze: haze, cornerRadius: cornerRadius) }

    final class RimView: NSView {
        /// Carries the shadow: the comet's own blurred light.
        private let glow = CALayer()
        /// Clipped to the ring.
        private let ring = CALayer()
        private let ringMask = CAShapeLayer()
        /// A conic comet that turns; the ring shows it only where it passes.
        private let comet = CAGradientLayer()
        private var applied: (HazeColor, CGFloat)?

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            glow.shadowOffset = .zero
            glow.shadowRadius = 4
            glow.shadowOpacity = 0.9
            ringMask.fillColor = nil
            ringMask.strokeColor = NSColor.black.cgColor
            ringMask.lineWidth = 2.5
            ring.mask = ringMask
            comet.type = .conic
            comet.startPoint = CGPoint(x: 0.5, y: 0.5)
            comet.endPoint = CGPoint(x: 0.5, y: 0)
            let arc = 70.0 / 360.0, lead = 4.0 / 360.0
            comet.locations = [0, 0.5 - arc, 0.5 - arc * 0.4, 0.5, 0.5 + lead, 1].map { NSNumber(value: $0) }
            ring.addSublayer(comet)
            glow.addSublayer(ring)
            layer?.addSublayer(glow)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            glow.frame = bounds
            ring.frame = bounds
            ringMask.frame = bounds
            // Snug outside the avatar's edge: 2pt of light, 1pt proud of it.
            let radius = applied?.1 ?? 0
            let avatar = bounds.insetBy(dx: WorkingRimLayer.bleed, dy: WorkingRimLayer.bleed)
            ringMask.path = RoundedRectangle(cornerRadius: radius + 1, style: .continuous)
                .path(in: avatar.insetBy(dx: -1, dy: -1)).cgPath
            // A square the ring never leaves while it turns.
            let side = hypot(bounds.width, bounds.height)
            comet.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            comet.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { turn() }
        }

        func apply(haze: HazeColor, cornerRadius: CGFloat) {
            if let applied, applied.0 == haze, applied.1 == cornerRadius { return }
            applied = (haze, cornerRadius)
            let light = NSColor(haze.edgeLight)
            let clear = light.withAlphaComponent(0).cgColor
            comet.colors = [clear, clear, light.withAlphaComponent(0.6).cgColor, light.cgColor, clear, clear]
            // A faint whole outline under the comet, so the avatar reads as lit.
            ring.backgroundColor = light.withAlphaComponent(0.22).cgColor
            glow.shadowColor = light.cgColor
            needsLayout = true
            turn()
        }

        private func turn() {
            guard comet.animation(forKey: "turn") == nil else { return }
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 2.6
            spin.repeatCount = .infinity
            spin.timingFunction = CAMediaTimingFunction(name: .linear)
            spin.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            comet.add(spin, forKey: "turn")
        }
    }
}
