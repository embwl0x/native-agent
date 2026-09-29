import AppToolRuntime
import SwiftUI

// "Alive glass" (User, 2026-09-23): while she is working on a turn and has not
// started her reply, light moves in the glass — a caustic shimmer in the
// composer and the rail, and a line of light travelling round the composer's
// edge. Agent, same day: it stops (0.4s fade) the moment reply text starts
// streaming, and stays off while it streams; the words are the signal then.
//
// Performance: everything here is a leaf. The signal is read in `ThinkingGlow`
// itself, never in ChatView or the composer, so a lifecycle tick invalidates
// this view and nothing else. The motion is Core Animation in a layer that
// sits in a background/overlay: the render server runs it, so a frame costs
// the app nothing, and an overlay is sized by its host and never proposes a
// size back, so it re-lays-out nothing. The fade animates one @State that
// only this leaf reads, so its transaction never reaches anything else.

extension AppModel {
    /// She is working on the open conversation's turn and no reply text has
    /// streamed yet. A retry resets the streamed length, so a retried turn
    /// reads as thinking again until its new text arrives.
    var isThinkingBeforeReply: Bool {
        guard isBusy || isChatStreaming else { return false }
        guard let lifecycle = engine.turns.lifecycle(for: activeChatSessionId) else { return true }
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
        if reduceMotion {
            // No travel: a still rim, a step brighter than the moving arc's
            // average, says she is thinking. No shimmer.
            if kind == .rim {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(haze.edgeLight.opacity(0.42), lineWidth: 1.5)
            }
        } else {
            // The rim's layer reaches past the host by `rimBleed` so its glow
            // is not clipped at the glass edge.
            ThinkingLightLayer(kind: kind, cornerRadius: cornerRadius, haze: haze)
                .padding(kind == .rim ? -Self.rimBleed : 0)
        }
    }

    static let rimBleed: CGFloat = 12
}

/// The moving light, on Core Animation: animations the render server runs, so
/// a thinking turn costs the main thread nothing per frame (a TimelineView
/// redrew every glow's Canvas each display frame). Both run on the wall
/// clock, so every glow on screen is in step.
private struct ThinkingLightLayer: NSViewRepresentable {
    let kind: ThinkingGlow.Kind
    let cornerRadius: CGFloat
    let haze: HazeColor

    func makeNSView(context: Context) -> LightView { LightView(kind: kind) }
    func updateNSView(_ view: LightView, context: Context) { view.apply(haze: haze, cornerRadius: cornerRadius) }

    final class LightView: NSView {
        private let kind: ThinkingGlow.Kind
        private var applied: (HazeColor, CGFloat)?
        private let content = CALayer()
        // Rim: a 2pt stroke of the rounded rectangle, lit by one 130° comet
        // of a conic gradient that turns once every `rimPeriod` — full
        // brightness at the head, fading back along the tail — over the same
        // arc 4pt wide, blurred 6pt at half opacity. The blur is `glow`'s
        // shadow, not a CIFilter, which would pull the layer tree back into
        // the app to render: `glow` sits out of view past the clip and casts
        // its shadow back in.
        private let glow = CALayer()
        private let glowRing = CALayer()
        private let glowMask = CAShapeLayer()
        private let glowComet = CAGradientLayer()
        private let ring = CALayer()
        private let ringMask = CAShapeLayer()
        private let comet = CAGradientLayer()
        // Shimmer: two soft radial pools of the haze's light shade sliding
        // past each other along the shape's long axis, trading brightness.
        private let clip = CAShapeLayer()
        private let pools = [CAGradientLayer(), CAGradientLayer()]

        init(kind: ThinkingGlow.Kind) {
            self.kind = kind
            super.init(frame: .zero)
            wantsLayer = true
            content.masksToBounds = true
            layer?.addSublayer(content)
            switch kind {
            case .rim:
                glow.shadowOpacity = 0.5
                glow.shadowRadius = 6
                for (holder, mask, gradient) in [(glowRing, glowMask, glowComet), (ring, ringMask, comet)] {
                    mask.fillColor = nil
                    mask.strokeColor = NSColor.black.cgColor
                    holder.mask = mask
                    // CA's conic runs anticlockwise from its end point, SwiftUI's
                    // clockwise: the stops are reversed to draw the same comet.
                    gradient.type = .conic
                    gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
                    gradient.endPoint = CGPoint(x: 1, y: 0.5)
                    gradient.locations = Self.cometStops.reversed().map { NSNumber(value: 1 - $0.location) }
                    holder.addSublayer(gradient)
                }
                glowMask.lineWidth = 4
                ringMask.lineWidth = 2
                glow.addSublayer(glowRing)
                content.addSublayer(glow)
                content.addSublayer(ring)
            case .shimmer:
                content.mask = clip
                for pool in pools {
                    pool.type = .radial
                    pool.startPoint = CGPoint(x: 0.5, y: 0.5)
                    pool.endPoint = CGPoint(x: 1, y: 1)
                    content.addSublayer(pool)
                }
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private static let arc = 130.0 / 360.0, lead = 4.0 / 360.0
        /// The comet's gradient as SwiftUI draws it: location clockwise from
        /// the start angle, and the light's opacity there.
        private static let cometStops: [(location: Double, alpha: Double)] = [
            (0, 0), (0.5 - arc, 0), (0.5 - arc * 0.4, 0.35), (0.5, 1), (0.5 + lead, 0), (1, 0),
        ]

        func apply(haze: HazeColor, cornerRadius: CGFloat) {
            if let applied, applied.0 == haze, applied.1 == cornerRadius { return }
            applied = (haze, cornerRadius)
            let light = NSColor(haze.edgeLight)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            switch kind {
            case .rim:
                let colors = Self.cometStops.reversed().map { light.withAlphaComponent($0.alpha).cgColor }
                glowComet.colors = colors
                comet.colors = colors
                glow.shadowColor = light.cgColor
            case .shimmer:
                for pool in pools { pool.colors = [light.cgColor, light.withAlphaComponent(0).cgColor] }
            }
            CATransaction.commit()
            needsLayout = true
        }

        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true }
        override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true }

        /// Sizes the layers and (re)starts the motion at the wall clock's phase.
        override func layout() {
            super.layout()
            guard let applied, bounds.width > 0, bounds.height > 0 else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let scale = window?.backingScaleFactor ?? 2
            for layer in [content, glow, glowRing, glowMask, glowComet, ring, ringMask, comet, clip] + pools {
                layer.contentsScale = scale
            }
            content.frame = bounds
            switch kind {
            case .rim: layoutRim(cornerRadius: applied.1)
            case .shimmer: layoutShimmer(cornerRadius: applied.1)
            }
            CATransaction.commit()
        }

        private func layoutRim(cornerRadius: CGFloat) {
            let line: CGFloat = 2
            let inset = ThinkingGlowLayer.rimBleed + line / 2
            let path = RoundedRectangle(cornerRadius: max(0, cornerRadius - line / 2), style: .continuous)
                .path(in: bounds.insetBy(dx: inset, dy: inset)).cgPath
            let away = bounds.width + 64
            glow.frame = bounds.offsetBy(dx: -away, dy: 0)
            glow.shadowOffset = CGSize(width: away, height: 0)
            // A square the ring never leaves while the comet turns.
            let side = hypot(bounds.width, bounds.height)
            for (holder, mask, gradient) in [(glowRing, glowMask, glowComet), (ring, ringMask, comet)] {
                holder.frame = bounds
                mask.frame = bounds
                mask.path = path
                gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
                // Clockwise, as SwiftUI's angle turns: negative about z here.
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = -2 * Double.pi
                spin.duration = ThinkingGlowLayer.rimPeriod
                spin.repeatCount = .infinity
                spin.timeOffset = Self.phase(ThinkingGlowLayer.rimPeriod)
                gradient.add(spin, forKey: "turn")
            }
        }

        private func layoutShimmer(cornerRadius: CGFloat) {
            let size = bounds.size
            clip.frame = bounds
            clip.path = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: bounds).cgPath
            let wide = size.width >= size.height
            let radius = max(min(size.width, size.height) * 1.3, 60)
            // One there-and-back: theta runs 0…2π over twice `shimmerSlide`.
            let period = ThinkingGlowLayer.shimmerSlide * 2
            let thetas = (0...96).map { Double($0) / 96 * 2 * .pi }
            for (pool, (across, sign)) in zip(pools, [(0.3, 1.0), (0.75, -1.0)]) {
                pool.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
                // SwiftUI's y runs down, this layer's up.
                func center(_ theta: Double) -> NSValue {
                    let along = 0.5 + sign * 0.55 * sin(theta)
                    return NSValue(point: wide
                        ? CGPoint(x: size.width * along, y: size.height * (1 - across))
                        : CGPoint(x: size.width * across, y: size.height * (1 - along)))
                }
                let move = CAKeyframeAnimation(keyPath: "position")
                move.values = thetas.map(center)
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = thetas.map { 0.30 * (0.55 + sign * 0.45 * cos($0)) }
                let slide = CAAnimationGroup()
                slide.animations = [move, fade]
                slide.duration = period
                slide.repeatCount = .infinity
                slide.timeOffset = Self.phase(period)
                pool.add(slide, forKey: "slide")
            }
        }

        /// Where the wall clock is in a loop of `period`: the phase the
        /// TimelineView drew, shared by every glow.
        private static func phase(_ period: Double) -> Double {
            Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        }
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
